import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ModuleManager()
    private var reconcileTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.onChange = { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            self.populate(menu)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "WinHub")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Auto-enable launch-at-login on first run — WinHub should just come back
        // after a reboot. The user can turn it off from the menu.
        if !UserDefaults.standard.bool(forKey: "didSetupLoginItem") {
            LoginItem.setEnabled(true)
            UserDefaults.standard.set(true, forKey: "didSetupLoginItem")
        }

        manager.bootstrap()
        populate(menu)

        // Permissions are granted out-of-process (System Settings) with no callback,
        // so poll: a module flips on within ~2s of being granted.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.manager.reconcile()
        }
    }

    // MARK: - Menu

    /// Box for stashing a `Permission` (a value type) in `representedObject` (Any?).
    private final class PermissionBox: NSObject {
        let value: Permission
        init(_ value: Permission) { self.value = value }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "WinHub \(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for module in manager.modules {
            let item = NSMenuItem(title: module.title,
                                  action: #selector(toggleModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.id
            item.toolTip = module.summary
            item.state = manager.isEnabled(module) ? .on : .off

            if !module.isAvailable {
                item.action = nil           // disabled toggle
                item.title = "\(module.title)  —  coming next"
            }
            menu.addItem(item)

            // Surface a missing permission for an enabled module as an actionable row.
            if manager.isEnabled(module) && module.isAvailable {
                for permission in module.requiredPermissions where !permission.isGranted {
                    let warn = NSMenuItem(title: "⚠︎ Grant \(permission.displayName)…",
                                          action: #selector(grantPermission(_:)), keyEquivalent: "")
                    warn.target = self
                    warn.representedObject = PermissionBox(permission)
                    warn.indentationLevel = 1
                    menu.addItem(warn)
                }
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let about = NSMenuItem(title: "About WinHub", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // Handy after granting Screen Recording — ScreenCaptureKit only sees the grant
        // on a fresh launch.
        let relaunch = NSMenuItem(title: "Relaunch WinHub", action: #selector(relaunchApp), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        let quit = NSMenuItem(title: "Quit WinHub", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        manager.toggle(id: id)
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PermissionBox else { return }
        Permissions.openSettings(for: box.value)
        switch box.value {
        case .accessibility:   Permissions.requestAccessibility()
        case .screenRecording: Permissions.requestScreenRecording()
        }
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        if let menu = statusItem.menu { populate(menu) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: NSAttributedString(
                string: "Windows comforts for macOS.\nA hub of small lifestyle tweaks.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    @objc private func relaunchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // Refresh permission rows each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        manager.reconcile()
        populate(menu)
    }
}
