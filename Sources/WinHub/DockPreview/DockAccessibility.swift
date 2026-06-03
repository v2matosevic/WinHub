import AppKit
import ApplicationServices

/// Accessibility plumbing for the Dock: given a screen point (top-left origin, as
/// the cursor reports), find the application Dock tile under it, resolve the running
/// app, and report the tile's frame in Cocoa (bottom-left) coordinates for panel
/// placement.
enum DockAccessibility {
    struct Tile {
        let appName: String
        let bundleID: String?
        let runningApp: NSRunningApplication?
        let frameCocoa: CGRect
    }

    static func tile(atTopLeft point: CGPoint) -> Tile? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        // Only application tiles — skip folders, separators, minimized-window tiles, Trash.
        guard string(hit, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }

        let name = string(hit, kAXTitleAttribute) ?? ""
        let bundle = bundleID(from: hit)
        return Tile(appName: name,
                    bundleID: bundle,
                    runningApp: resolve(bundleID: bundle, name: name),
                    frameCocoa: frameCocoa(of: hit))
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
