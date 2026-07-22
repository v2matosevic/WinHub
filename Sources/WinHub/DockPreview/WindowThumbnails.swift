import AppKit
import ScreenCaptureKit

/// A captured thumbnail of one window.
struct WindowShot {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let title: String
    /// The window's on-screen frame in AX (top-left origin) coordinates — used to
    /// match a shot back to its AX window when the title is empty or ambiguous.
    /// `.zero` for placeholder shots (minimized windows) that were never captured.
    let frame: CGRect
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

/// Captures window thumbnails via ScreenCaptureKit. Requires Screen Recording
/// permission; returns an empty array if it's missing or no windows are eligible.
final class WindowThumbnailService {
    /// Shareable content enumerates every on-screen window system-wide — cache it
    /// briefly so sweeping across several Dock tiles doesn't re-enumerate per hover.
    private var cachedContent: (content: SCShareableContent, at: Date)?

    /// All of one application's on-screen windows, ordered by windowID (stable
    /// across hovers). `maxDimension` is in points and should roughly match the
    /// largest size the UI displays a thumbnail at.
    func capture(appPID: pid_t, maxDimension: CGFloat = 160) async -> [WindowShot] {
        guard let content = await shareableContent() else { return [] }
        let windows = content.windows
            .filter { isStandard($0) && $0.owningApplication?.processID == appPID }
            .sorted { $0.windowID < $1.windowID }
        return await shots(of: windows, maxDimension: maxDimension)
    }

    /// Snap Assist candidates: every standard on-screen window except our own and
    /// the already-placed ones (`excluding`, matched by owner pid + title). Kept in
    /// the front-to-back order ScreenCaptureKit reports, so recently used windows
    /// come first.
    func captureSnapCandidates(excluding: [(pid: pid_t, title: String)],
                               maxDimension: CGFloat = 280, limit: Int = 9) async -> [WindowShot] {
        guard let content = await shareableContent() else { return [] }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let windows = content.windows.filter { window in
            guard isStandard(window), let owner = window.owningApplication?.processID,
                  owner != ownPID else { return false }
            let title = window.title ?? ""
            return !excluding.contains { $0.pid == owner && $0.title == title }
        }
        return await shots(of: Array(windows.prefix(limit)), maxDimension: maxDimension)
    }

    // MARK: - Internals

    private func shareableContent() async -> SCShareableContent? {
        if let cached = cachedContent, Date().timeIntervalSince(cached.at) < 0.5 {
            return cached.content
        }
        guard let fresh = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        cachedContent = (fresh, Date())
        return fresh
    }

    private func isStandard(_ window: SCWindow) -> Bool {
        window.isOnScreen && window.windowLayer == 0 &&      // normal windows only
        window.frame.width > 50 && window.frame.height > 50
    }

    /// Capture concurrently — latency is the slowest single window, not the sum.
    /// Results come back in the order `windows` was passed in.
    private func shots(of windows: [SCWindow], maxDimension: CGFloat) async -> [WindowShot] {
        let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }

        let indexed = await withTaskGroup(of: (Int, WindowShot)?.self) { group in
            for (index, window) in windows.enumerated() {
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
                    return (index, WindowShot(windowID: window.windowID,
                                              ownerPID: window.owningApplication?.processID ?? 0,
                                              title: window.title ?? "",
                                              frame: window.frame,
                                              image: image))
                }
            }
            var collected: [(Int, WindowShot)] = []
            for await shot in group { if let shot { collected.append(shot) } }
            return collected
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
