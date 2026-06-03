import AppKit

/// Roadmap module — the headline feature. Hovering a Dock icon should show live
/// window thumbnails (Windows taskbar style). The implementation needs Accessibility
/// (map cursor → Dock tile → app), Screen Recording (ScreenCaptureKit thumbnails),
/// and a floating preview panel. Registered now so the hub shows where it's going;
/// `isAvailable` stays false until it's built.
final class DockPreviewModule: HubModule {
    let id = "dock-preview"
    let title = "Dock hover previews"
    let summary = "Window thumbnails when you hover a Dock icon."
    let requiredPermissions: [Permission] = [.accessibility, .screenRecording]
    let isAvailable = false
    private(set) var isRunning = false

    func start() { isRunning = true }
    func stop()  { isRunning = false }
}
