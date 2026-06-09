import AppKit
import ScreenCaptureKit

/// A captured thumbnail of one window.
struct WindowShot {
    let windowID: CGWindowID
    let title: String
    let image: CGImage
}

extension NSImage {
    /// A CGImage backing at roughly `pixelSize`, picking a hi-res representation when
    /// available — used to show an app icon as a placeholder for minimized windows.
    func cgImageRep(pixelSize: CGFloat = 256) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        return cgImage(forProposedRect: &rect, context: nil,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
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

        // Capture concurrently — panel latency is the slowest single window, not the
        // sum. Order is restored by the windowID sort below.
        let shots = await withTaskGroup(of: WindowShot?.self) { group in
            for window in windows {
                group.addTask {
                    let scale = min(1, maxDimension / max(window.frame.width, window.frame.height))
                    let config = SCStreamConfiguration()
                    config.width  = max(1, Int(window.frame.width  * scale * 2))   // 2x for crispness
                    config.height = max(1, Int(window.frame.height * scale * 2))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true

                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let image = try? await SCScreenshotManager
                        .captureImage(contentFilter: filter, configuration: config) else { return nil }
                    return WindowShot(windowID: window.windowID, title: window.title ?? "", image: image)
                }
            }
            var collected: [WindowShot] = []
            for await shot in group { if let shot { collected.append(shot) } }
            return collected
        }
        return shots.sorted { $0.windowID < $1.windowID }
    }
}
