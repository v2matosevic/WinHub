import AppKit
import ScreenCaptureKit

/// A captured thumbnail of one window.
struct WindowShot {
    let windowID: CGWindowID
    let title: String
    let image: CGImage
}

/// Captures thumbnails of an application's on-screen windows via ScreenCaptureKit.
/// Requires Screen Recording permission; returns an empty array if it's missing or
/// the app has no eligible windows.
final class WindowThumbnailService {
    func capture(appPID: pid_t, maxDimension: CGFloat = 320) async -> [WindowShot] {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }

        let windows = content.windows
            .filter { window in
                window.owningApplication?.processID == appPID &&
                window.isOnScreen &&
                window.windowLayer == 0 &&             // normal windows only
                window.frame.width > 50 && window.frame.height > 50
            }
            .sorted { $0.windowID < $1.windowID }

        var shots: [WindowShot] = []
        for window in windows {
            let scale = min(1, maxDimension / max(window.frame.width, window.frame.height))
            let config = SCStreamConfiguration()
            config.width  = max(1, Int(window.frame.width  * scale * 2))   // 2x for crispness
            config.height = max(1, Int(window.frame.height * scale * 2))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                shots.append(WindowShot(windowID: window.windowID, title: window.title ?? "", image: image))
            }
        }
        return shots
    }
}
