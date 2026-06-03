import AppKit
import ApplicationServices

/// Per-application Accessibility watcher. One exists for each regular running app;
/// it owns that app's AXObserver and the back-reference the C callback needs.
private final class AppWatcher {
    let pid: pid_t
    let bundleID: String
    let appElement: AXUIElement
    var observer: AXObserver?
    weak var module: CloseToQuitModule?

    init(pid: pid_t, bundleID: String, module: CloseToQuitModule) {
        self.pid = pid
        self.bundleID = bundleID
        self.appElement = AXUIElementCreateApplication(pid)
        self.module = module
    }
}

/// AXObserver fires through a C function pointer, so the trampoline must be a free
/// function. `refcon` carries the (unretained) AppWatcher that owns the observer.
private func closeToQuitAXCallback(_ observer: AXObserver,
                                   _ element: AXUIElement,
                                   _ notification: CFString,
                                   _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.module?.handle(notification: notification as String, element: element, watcher: watcher)
}

/// Windows-style window management: when an app's last standard window is closed,
/// quit the app — gracefully, so unsaved-work prompts still appear.
final class CloseToQuitModule: HubModule {
    let id = "close-to-quit"
    let title = "Close button quits app"
    let summary = "Closing the last window quits the app, Windows-style."
    let requiredPermissions: [Permission] = [.accessibility]
    private(set) var isRunning = false

    /// Apps we must never auto-quit. The OS/shell ones would break the desktop; the
    /// rest are agents the user never "closes" in the Windows sense.
    private let builtinDenylist: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",   // System Settings
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "hr.version2.winhub",            // ourselves
    ]

    private var watchers: [pid_t: AppWatcher] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    /// Built-in denylist plus any bundle IDs the user has excluded.
    private var denylist: Set<String> {
        let user = UserDefaults.standard.stringArray(forKey: "closeToQuit.userExclusions") ?? []
        return builtinDenylist.union(user)
    }

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.attach(to: app)
                }
            })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.detach(pid: app.processIdentifier)
                }
            })

        for app in NSWorkspace.shared.runningApplications {
            attach(to: app)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        workspaceTokens.removeAll()
        for pid in Array(watchers.keys) { detach(pid: pid) }
    }

    // MARK: - Attach / detach

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              !denylist.contains(bundleID),
              watchers[app.processIdentifier] == nil else { return }

        let pid = app.processIdentifier
        var observer: AXObserver?
        guard AXObserverCreate(pid, closeToQuitAXCallback, &observer) == .success,
              let observer else { return }

        let watcher = AppWatcher(pid: pid, bundleID: bundleID, module: self)
        watcher.observer = observer
        let refcon = Unmanaged.passUnretained(watcher).toOpaque()

        // New windows on this app — we register destruction-watchers as they appear.
        AXObserverAddNotification(observer, watcher.appElement, kAXWindowCreatedNotification as CFString, refcon)
        // ...and watch the windows that already exist.
        for window in standardWindows(of: watcher.appElement) {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        watchers[pid] = watcher
    }

    private func detach(pid: pid_t) {
        guard let watcher = watchers[pid] else { return }
        if let observer = watcher.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        watcher.observer = nil
        watcher.module = nil
        watchers[pid] = nil
    }

    // MARK: - Callback handling

    fileprivate func handle(notification: String, element: AXUIElement, watcher: AppWatcher) {
        switch notification {
        case kAXWindowCreatedNotification:
            // `element` is the freshly created window — watch for its destruction.
            if let observer = watcher.observer {
                AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                          Unmanaged.passUnretained(watcher).toOpaque())
            }
        case kAXUIElementDestroyedNotification:
            // A window went away. Let AX settle, then quit the app if nothing standard remains.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak watcher] in
                guard let self, let watcher else { return }
                self.quitIfNoStandardWindows(watcher: watcher)
            }
        default:
            break
        }
    }

    private func quitIfNoStandardWindows(watcher: AppWatcher) {
        guard isRunning,
              let app = NSRunningApplication(processIdentifier: watcher.pid),
              !app.isTerminated,
              !denylist.contains(watcher.bundleID) else { return }

        if standardWindows(of: watcher.appElement).isEmpty {
            app.terminate()   // graceful: the app can still present a save dialog
        }
    }

    // MARK: - AX helpers

    /// Visible top-level "standard" windows (excludes sheets, popovers, panels).
    private func standardWindows(of appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.filter { isStandardWindow($0) }
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else {
            return true   // unknown subrole: count it, so we err toward NOT quitting
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }
}
