import Foundation

/// One self-contained tweak in the WinHub hub. Modules are registered in
/// `ModuleManager`, surfaced as toggles in the menu-bar menu, and persist their
/// on/off state across launches.
protocol HubModule: AnyObject {
    /// Stable identifier used for persistence; never change once shipped.
    var id: String { get }
    /// Menu title.
    var title: String { get }
    /// One-line description (shown as a tooltip).
    var summary: String { get }
    /// Permissions that must be granted before `start()` does anything useful.
    var requiredPermissions: [Permission] { get }
    /// Whether the feature is built yet. Unavailable modules still appear in the
    /// menu (so the roadmap is visible) but their toggle is disabled.
    var isAvailable: Bool { get }
    /// Whether the module is currently active.
    var isRunning: Bool { get }

    func start()
    func stop()
}

extension HubModule {
    var isAvailable: Bool { true }
}
