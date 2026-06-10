import AppKit

/// Boring Notch-style hub around the camera notch: a music live activity when
/// closed; hover (or click) to expand into playback controls and a drop shelf.
final class NotchModule: HubModule {
    let id = "notch-hub"
    let title = "Dynamic notch"
    let summary = "Hover the notch for music controls; drop files on it to stash and AirDrop them."
    let requiredPermissions: [Permission] = []
    private(set) var isRunning = false

    private var controller: NotchController?

    func start() {
        guard !isRunning else { return }
        MainActor.assumeIsolated {
            let controller = NotchController()
            controller.start()
            self.controller = controller
        }
        isRunning = true
        NSLog("[WinHub.notch] started")
    }

    func stop() {
        guard isRunning else { return }
        MainActor.assumeIsolated {
            controller?.stop()
            controller = nil
        }
        isRunning = false
        NSLog("[WinHub.notch] stopped")
    }
}
