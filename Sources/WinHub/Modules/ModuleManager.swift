import Foundation

/// Owns the set of modules, their persisted enabled-state, and the logic that
/// (re)starts them once their permissions are in place.
final class ModuleManager {
    let modules: [HubModule]
    /// Called when observable state changes (a toggle, or a module became runnable
    /// after a permission was granted) so the UI can refresh.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        modules = [
            CloseToQuitModule(),
            SnapModule(),
            SnapToGridModule(),
            DockPreviewModule(),
            NotchModule(),
        ]
        // Snap-to-grid ships on by default — it's a harmless, instantly-reversible
        // Finder default, so new users get the tidy-grid behavior out of the box.
        defaults.register(defaults: [key("snap-to-grid"): true])
        NotchSettings.registerDefaults()
    }

    private func key(_ id: String) -> String { "module.\(id).enabled" }

    func isEnabled(_ module: HubModule) -> Bool { isEnabled(id: module.id) }
    func isEnabled(id: String) -> Bool { defaults.bool(forKey: key(id)) }

    /// Start every enabled module whose permissions are satisfied. Called once at launch.
    func bootstrap() {
        for module in modules where isEnabled(module) {
            startIfPermitted(module)
        }
    }

    func toggle(id: String) {
        guard let module = modules.first(where: { $0.id == id }), module.isAvailable else { return }
        let newValue = !isEnabled(module)
        defaults.set(newValue, forKey: key(module.id))

        if newValue {
            for permission in module.requiredPermissions where !permission.isGranted {
                requestPermission(permission)
            }
            startIfPermitted(module)
        } else {
            module.stop()
        }
        onChange?()
    }

    /// Start any enabled-but-not-running module whose permissions are now granted.
    /// Fires `onChange` (and returns true) if anything actually started.
    @discardableResult
    func reconcile() -> Bool {
        var changed = false
        for module in modules where isEnabled(module) && !module.isRunning && module.isAvailable {
            if module.requiredPermissions.allSatisfy({ $0.isGranted }) {
                module.start()
                changed = changed || module.isRunning
            }
        }
        if changed { onChange?() }
        return changed
    }

    /// True while an enabled module is waiting (usually on a permission) — i.e.
    /// while polling `reconcile()` can still achieve something.
    var hasPendingModules: Bool {
        modules.contains { isEnabled($0) && $0.isAvailable && !$0.isRunning }
    }

    private func startIfPermitted(_ module: HubModule) {
        guard module.isAvailable,
              module.requiredPermissions.allSatisfy({ $0.isGranted }) else { return }
        module.start()
    }

    private func requestPermission(_ permission: Permission) {
        switch permission {
        case .accessibility:
            Permissions.requestAccessibility()
            Permissions.openSettings(for: .accessibility)
        case .screenRecording:
            Permissions.requestScreenRecording()
            Permissions.openSettings(for: .screenRecording)
        }
    }
}
