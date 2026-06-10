import AppKit

/// Frame math for the notch window: where the physical notch is, how big the
/// closed pill and the expanded hub are.
enum NotchGeometry {
    /// The expanded hub content size.
    static let openSize = CGSize(width: 640, height: 190)
    /// Extra window height below the hub so its drop shadow isn't clipped.
    static let shadowPadding: CGFloat = 20
    static var windowSize: CGSize {
        CGSize(width: openSize.width, height: openSize.height + shadowPadding)
    }

    /// The screen the notch UI lives on: the one with a physical notch,
    /// otherwise the main screen (where it renders as a menu-bar-height pill).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The closed pill: exactly the camera-housing cutout on notch hardware,
    /// a menu-bar-height pill elsewhere.
    static func closedSize(on screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0 {
            var width: CGFloat = 185
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = screen.frame.width - left.width - right.width
            }
            return CGSize(width: width, height: screen.safeAreaInsets.top)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 185, height: min(38, max(24, menuBar)))
    }

    /// Window frame: top-center of the screen (Cocoa coordinates).
    static func windowFrame(on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - windowSize.width / 2,
               y: screen.frame.maxY - windowSize.height,
               width: windowSize.width,
               height: windowSize.height)
    }
}
