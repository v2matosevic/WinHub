import AppKit
import ApplicationServices

/// Accessibility plumbing for the Dock: given a screen point (top-left origin, as
/// the cursor reports), find the application Dock tile under it, resolve the running
/// app, and report the tile's frame in Cocoa (bottom-left) coordinates for panel
/// placement.
enum DockOrientation { case bottom, left, right }

enum DockAccessibility {
    struct Tile {
        let appName: String
        let bundleID: String?
        let runningApp: NSRunningApplication?
        let frameCocoa: CGRect
        let orientation: DockOrientation
    }

    /// Tiles whose subrole we can confidently skip without resolving an app.
    private static let nonAppSubroles: Set<String> = [
        "AXSeparatorDockItem", "AXFolderDockItem", "AXTrashDockItem",
        "AXURLDockItem", "AXDocumentDockItem",
    ]

    static func tile(atTopLeft point: CGPoint) -> Tile? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        // Don't hard-gate on the app subrole — the exact constant is easy to get wrong
        // across macOS versions. Skip only the obvious non-app tiles; everything else
        // is accepted and filtered by whether it resolves to a running regular app.
        if let subrole = string(hit, kAXSubroleAttribute), nonAppSubroles.contains(subrole) { return nil }

        let name = string(hit, kAXTitleAttribute) ?? ""
        let bundle = bundleID(from: hit)
        return Tile(appName: name,
                    bundleID: bundle,
                    runningApp: resolve(bundleID: bundle, name: name),
                    frameCocoa: frameCocoa(of: hit),
                    orientation: orientation())
    }

    /// Dock edge, read from the Dock's own preferences (defaults to bottom).
    static func orientation() -> DockOrientation {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left":  return .left
        case "right": return .right
        default:      return .bottom
        }
    }

    /// Titles of an app's currently-minimized windows (macOS can't live-capture these,
    /// so the preview shows the app icon for them).
    static func minimizedWindowTitles(forPID pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  (minimized as? Bool) == true else { return nil }
            return string(window, kAXTitleAttribute) ?? ""
        }
    }

    /// Convert a cursor point (top-left origin) to Cocoa screen coordinates.
    static func cocoaPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: - Helpers

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bundleID(from tile: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tile, "AXURL" as CFString, &value) == .success else { return nil }
        let url = (value as? URL) ?? (value as? NSURL).map { $0 as URL }
        guard let url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private static func resolve(bundleID: String?, name: String) -> NSRunningApplication? {
        if let bundleID, let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.localizedName == name
        }
    }

    private static func frameCocoa(of tile: AXUIElement) -> CGRect {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tile, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(tile, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return .zero
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)   // top-left origin
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }
}
