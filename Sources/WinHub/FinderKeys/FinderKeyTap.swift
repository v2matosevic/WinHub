import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The event tap runs through a C function pointer, so the trampoline is a free
/// function; `refcon` carries the (unretained) tap, kept alive by its module.
private func finderKeyTapCallback(_ proxy: CGEventTapProxy,
                                  _ type: CGEventType,
                                  _ event: CGEvent,
                                  _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<FinderKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

/// Rewrites a handful of keys to their Windows meanings, but *only* in Finder:
/// Delete moves to the Trash, F2 renames, Return opens. Each is a translation
/// into the shortcut macOS already has, so Finder's own undo, sounds and
/// confirmations all behave exactly as if you'd pressed ⌘⌫ / ↩ / ⌘↓ yourself.
///
/// This sits on the keystroke path for the whole session, so every decision is
/// biased toward doing nothing: a non-Finder frontmost app is a single cached
/// Bool, any modifier at all passes through untouched, and any focus we can't
/// positively clear as "the file view" passes through too. The failure mode of
/// a wrong guess here is a user who can't press Return.
final class FinderKeyTap {
    /// Stamped on the events we inject so the tap ignores its own output instead
    /// of translating it again. ('WHFK')
    private static let injectedTag: Int64 = 0x5748_464B

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventSource: CGEventSource?

    /// Cheap gate: unless Finder is frontmost the callback does nothing but read
    /// this Bool, so every other app's keystrokes cost a branch.
    private var frontmostIsFinder = false
    private var finderElement: AXUIElement?
    private var finderPID: pid_t = 0
    private var workspaceTokens: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // must be able to swallow, not just observe
            eventsOfInterest: CGEventMask(mask),
            callback: finderKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("[WinHub.finderkeys] could not create the event tap — Accessibility missing?")
            return false
        }
        tap = newTap
        eventSource = CGEventSource(stateID: .hidSystemState)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = source
        // Common modes so the translations keep working while a menu or a window
        // resize is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFrontmost() })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self?.finderPID else { return }
            self?.finderElement = nil       // Finder restarted; re-resolve on next activation
            self?.finderPID = 0
        })
        updateFrontmost()

        NSLog("[WinHub.finderkeys] started")
        return true
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        workspaceTokens.removeAll()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        eventSource = nil
        finderElement = nil
        finderPID = 0
        frontmostIsFinder = false
        NSLog("[WinHub.finderkeys] stopped")
    }

    private func updateFrontmost() {
        let app = NSWorkspace.shared.frontmostApplication
        frontmostIsFinder = app?.bundleIdentifier == "com.apple.finder"
        guard frontmostIsFinder, let app, app.processIdentifier != finderPID else { return }
        finderPID = app.processIdentifier
        let element = AXUIElementCreateApplication(finderPID)
        // The focus probes below run *on the keystroke path*. A wedged Finder must
        // never be able to hold the keyboard hostage, so cap the wait hard (the AX
        // default is 6 s).
        AXUIElementSetMessagingTimeout(element, 0.05)
        finderElement = element
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // The system disables a tap that takes too long, or across a secure input
        // transition — turn it back on rather than silently going dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }
        guard type == .keyDown || type == .keyUp else { return passThrough }
        guard frontmostIsFinder else { return passThrough }
        // Our own injected replacement, coming back around the loop.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.injectedTag else { return passThrough }

        // Any real modifier means the user asked for something specific — including
        // the macOS shortcuts we translate *into*, which must keep working. Fn is
        // ignored: on a laptop, fn+⌫ *is* the Windows Delete key.
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(held).isEmpty else { return passThrough }

        guard let replacement = translation(for: event.getIntegerValueField(.keyboardEventKeycode)),
              focusIsFileView() else { return passThrough }

        guard let injected = CGEvent(keyboardEventSource: eventSource,
                                     virtualKey: replacement.keyCode,
                                     keyDown: type == .keyDown) else { return passThrough }
        injected.flags = replacement.flags
        injected.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
        injected.post(tap: .cgSessionEventTap)
        return nil   // swallow the original
    }

    private struct Replacement {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// Each translation targets a shortcut Finder already publishes in its own
    /// menus, so Finder does the work and we never touch a file ourselves.
    private func translation(for keyCode: Int64) -> Replacement? {
        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            // Windows: Delete → Recycle Bin. macOS: ⌘⌫ → Trash.
            guard FinderKeysSettings.deleteToTrash else { return nil }
            return Replacement(keyCode: CGKeyCode(kVK_Delete), flags: .maskCommand)
        case kVK_F2:
            // Windows: F2 → rename. macOS: ↩ → rename.
            guard FinderKeysSettings.f2Rename else { return nil }
            return Replacement(keyCode: CGKeyCode(kVK_Return), flags: [])
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Windows: Enter → open. macOS: ⌘↓ → open selection.
            guard FinderKeysSettings.enterOpens else { return nil }
            return Replacement(keyCode: CGKeyCode(kVK_DownArrow), flags: .maskCommand)
        default:
            return nil
        }
    }

    // MARK: - Focus

    /// Roles where Return and Delete already mean something the user wants: an
    /// inline rename, the search field, a comment box, a tracking menu, or the
    /// default button of a dialog. Rewriting a key in any of these is worse than
    /// not shipping the feature, so they all pass through untouched.
    private static let hazardRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXPopUpButtonRole as String,
        kAXButtonRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
        kAXMenuBarRole as String,
        kAXMenuBarItemRole as String,
        "AXSearchField",
    ]

    /// True when Finder's keyboard focus looks like the file view (a browser
    /// window's list/icon/column area, or the desktop) rather than somewhere a
    /// keystroke already has a meaning.
    private func focusIsFileView() -> Bool {
        guard let app = finderElement else { return false }

        // A sheet or dialog — Get Info, Connect to Server, an alert — is not the
        // file list. The desktop has no focused window at all, which is fine.
        if let window = element(app, kAXFocusedWindowAttribute),
           let subrole = string(window, kAXSubroleAttribute),
           subrole != (kAXStandardWindowSubrole as String) {
            return false
        }
        if let focused = element(app, kAXFocusedUIElementAttribute),
           let role = string(focused, kAXRoleAttribute),
           Self.hazardRoles.contains(role) {
            return false
        }
        return true
    }

    private func element(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success,
              let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
