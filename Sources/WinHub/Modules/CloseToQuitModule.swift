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
    /// When this app last reported a window being minimized (miniaturize event).
    var lastMiniaturizeAt: Date?

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
        // A window being minimized — registered on the app element, so it fires for
        // every window (current and future) without per-window bookkeeping. This is
        // how we tell a minimize apart from a close (see `confirmLastWindowClosed`).
        AXObserverAddNotification(observer, watcher.appElement, kAXWindowMiniaturizedNotification as CFString, refcon)
        // ...and watch the windows that already exist for destruction.
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
        case kAXWindowMiniaturizedNotification:
            // A window was minimized — that is never a "close". Remember it so a
            // destroyed-notification fired by the same minimize transition stands
            // the quit down.
            watcher.lastMiniaturizeAt = Date()
        case kAXUIElementDestroyedNotification:
            // A window went away — but this also fires mid-transition when an app
            // tears down a transient window without closing for real. The worst
            // offender is HTML5 fullscreen video: Chromium browsers (Brave/Chrome)
            // open a *separate* fullscreen window and destroy it when you press
            // Esc, during which the real browser window briefly drops out of the
            // AX window list. A single check would read "no windows" and quit the
            // whole browser. So re-confirm the list stays empty before quitting.
            confirmLastWindowClosed(watcher: watcher)
        default:
            break
        }
    }

    /// Quit only if the app's standard-window list is *stably* empty. We re-poll a
    /// few times (~1s total); any window that appears — e.g. the browser window
    /// returning after a fullscreen-video Esc — aborts the quit. This rides over
    /// the transient empty readings that fullscreen/space transitions produce.
    private func confirmLastWindowClosed(watcher: AppWatcher, remaining: Int = 6) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak watcher] in
            guard let self, let watcher, self.isRunning,
                  let app = NSRunningApplication(processIdentifier: watcher.pid),
                  !app.isTerminated,
                  !self.denylist.contains(watcher.bundleID) else { return }

            // A window was minimized in the last few seconds: this isn't a close, so
            // never quit (core Windows behavior — minimizing leaves the app on the
            // taskbar). The miniaturize event is the *reliable* signal here: on
            // minimize some apps (Lightroom Classic) tear down their windows and
            // briefly report an empty AX window list, which the old check misread as
            // a last-window close. The window list churns; the miniaturize event does
            // not. The 5s window comfortably covers the destroy/confirm transition.
            if let m = watcher.lastMiniaturizeAt, Date().timeIntervalSince(m) < 5 { return }

            // A standard or minimized window is present (or came back): not a close.
            guard !self.hasOpenWindows(of: watcher.appElement) else { return }

            if remaining > 1 {
                self.confirmLastWindowClosed(watcher: watcher, remaining: remaining - 1)
            } else {
                app.terminate()   // graceful: the app can still present a save dialog
            }
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

    /// True while the app still has a window that should *stand down* a quit: a
    /// visible standard window, or any minimized one. A minimized window is not a
    /// closed window, so it keeps the app alive (Windows-style). Some apps —
    /// Lightroom Classic among them — drop a window's `AXStandardWindow` subrole the
    /// moment it's minimized, which is why we test `AXMinimized` across every window
    /// instead of relying on the subrole filter alone.
    private func hasOpenWindows(of appElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return windows.contains { isStandardWindow($0) || isMinimized($0) }
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? false
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
