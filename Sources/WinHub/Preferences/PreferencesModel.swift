import AppKit
import Combine

/// An app the user has excluded from "close button quits app".
struct ExcludedApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID }

    init(bundleID: String) {
        self.bundleID = bundleID
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        self.name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        self.icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }
}

/// View-model bridging the SwiftUI Settings window to the existing `ModuleManager`,
/// `LoginItem`, and the close-to-quit exclusion list in `UserDefaults`.
final class PreferencesModel: ObservableObject {
    private let manager: ModuleManager
    private let defaults = UserDefaults.standard
    private let exclusionsKey = "closeToQuit.userExclusions"

    @Published private(set) var exclusions: [ExcludedApp] = []

    init(manager: ModuleManager) {
        self.manager = manager
        reloadExclusions()
    }

    var modules: [HubModule] { manager.modules }

    // MARK: Modules

    func isEnabled(_ module: HubModule) -> Bool { manager.isEnabled(module) }

    func setEnabled(_ enabled: Bool, _ module: HubModule) {
        guard manager.isEnabled(module) != enabled else { return }
        manager.toggle(id: module.id)
        objectWillChange.send()
    }

    func missingPermissions(_ module: HubModule) -> [Permission] {
        guard manager.isEnabled(module), module.isAvailable else { return [] }
        return module.requiredPermissions.filter { !$0.isGranted }
    }

    func grant(_ permission: Permission) {
        Permissions.openSettings(for: permission)
        switch permission {
        case .accessibility:   Permissions.requestAccessibility()
        case .screenRecording: Permissions.requestScreenRecording()
        }
        objectWillChange.send()
    }

    // MARK: Start at login

    var startAtLogin: Bool { LoginItem.isEnabled }
    func setStartAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        objectWillChange.send()
    }

    // MARK: Exclusions

    private var bundleIDs: [String] { defaults.stringArray(forKey: exclusionsKey) ?? [] }

    private func reloadExclusions() {
        exclusions = bundleIDs.map(ExcludedApp.init(bundleID:))
    }

    func addExclusion() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Choose an app that should stay open when its last window closes."
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        var ids = bundleIDs
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        defaults.set(ids, forKey: exclusionsKey)
        reloadExclusions()
    }

    func removeExclusion(_ app: ExcludedApp) {
        defaults.set(bundleIDs.filter { $0 != app.bundleID }, forKey: exclusionsKey)
        reloadExclusions()
    }

    /// Re-publish state (e.g. after a change made from the menu bar).
    func refresh() {
        reloadExclusions()
        objectWillChange.send()
    }
}
