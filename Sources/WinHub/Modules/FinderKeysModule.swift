import AppKit

/// Windows keyboard habits in Finder: Delete moves the selection to the Trash,
/// F2 renames it, Return opens it. The work is done by `FinderKeyTap`, which
/// rewrites each key into the macOS shortcut that already does the job.
///
/// Ships **off** by default. Every other module either adds something on top of
/// macOS or changes a Finder default; this one takes over three keys the user
/// presses all day, so it's opt-in.
final class FinderKeysModule: HubModule {
    let id = "finder-keys"
    let title = "Windows keys in Finder"
    let summary = "Delete moves to the Trash, F2 renames, Return opens — pick which in Settings."
    let requiredPermissions: [Permission] = [.accessibility]
    let isAvailable = true
    private(set) var isRunning = false

    private let tap = FinderKeyTap()

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        // A tap that won't create leaves the module not-running, so `reconcile()`
        // keeps retrying instead of reporting a feature that silently does nothing.
        guard tap.start() else { return }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tap.stop()
    }
}
