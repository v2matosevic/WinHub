import AppKit

/// Coordinate helpers. macOS hands us geometry in two systems: the cursor and
/// Accessibility use a top-left origin anchored to the primary display; AppKit
/// (NSScreen, NSWindow) uses a bottom-left origin. These convert between them.
enum ScreenGeometry {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    /// A cursor/AX point (top-left origin) → AppKit Cocoa point (bottom-left).
    static func cocoaPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// An AppKit Cocoa rect (bottom-left) → Accessibility rect (top-left origin).
    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(containing cocoaPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main
    }
}
