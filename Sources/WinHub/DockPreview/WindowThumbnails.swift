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
    /// Shareable content enumerates every on-screen window system-wide — cache it
    /// briefly so sweeping across several Dock tiles doesn't re-enumerate per hover.
    private var cachedContent: (content: SCShareableContent, at: Date)?

    /// `maxDimension` is in points and should roughly match the largest size the
    /// panel actually displays a thumbnail at (the cell is ~130 pt tall) — pixel
    /// size comes from multiplying by the screen's backing scale.
    func capture(appPID: pid_t, maxDimension: CGFloat = 160) async -> [WindowShot] {
        let content: SCShareableContent
        if let cached = cachedContent, Date().timeIntervalSince(cached.at) < 0.5 {
            content = cached.content
        } else {
            guard let fresh = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
            cachedContent = (fresh, Date())
            content = fresh
        }
        let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }

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
                    config.width  = max(1, Int(window.frame.width  * scale * displayScale))
                    config.height = max(1, Int(window.frame.height * scale * displayScale))
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
