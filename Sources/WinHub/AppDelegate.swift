import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ModuleManager()
    private var reconcileTimer: Timer?
    private lazy var preferencesModel = PreferencesModel(manager: manager)
    private var prefsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.onChange = { [weak self] in
            guard let self else { return }
            if let menu = self.statusItem.menu { self.populate(menu) }
            self.preferencesModel.refresh()
            self.syncReconcileTimer()
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
        syncReconcileTimer()

        // Allow opening Settings directly (e.g. `open WinHub.app --args --settings`).
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.openPreferences() }
        }
    }

    // MARK: - Reconcile timer

    /// Permissions are granted out-of-process (System Settings) with no callback, so
    /// poll — but only while an enabled module is actually waiting on one. Once
    /// everything is running the timer stops, so idle WinHub holds no timers here.
    /// `onChange` re-syncs it whenever a toggle creates (or clears) pending work.
    private func syncReconcileTimer() {
        if manager.hasPendingModules {
            guard reconcileTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.manager.reconcile()   // fires onChange (→ re-sync) if anything started
                if !self.manager.hasPendingModules { self.syncReconcileTimer() }
            }
            timer.tolerance = 0.5
            reconcileTimer = timer
        } else {
            reconcileTimer?.invalidate()
            reconcileTimer = nil
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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let about = NSMenuItem(title: "About WinHub", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

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

    @objc private func openPreferences() {
        if prefsWindow == nil {
            let hosting = NSHostingController(rootView: PreferencesView(model: preferencesModel))
            let window = NSWindow(contentViewController: hosting)
            window.title = "WinHub Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            prefsWindow = window
        }
        // An .accessory app can't reliably make a normal window key — become a
        // regular app while Settings is open, back to accessory when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === prefsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
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
                string: "Windows comforts for macOS.\nA hub of small lifestyle tweaks.\n\nMade by Version2 · MIT License",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    @objc private func checkForUpdates() {
        UpdateChecker.checkInteractively()
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
