import AppKit

/// A translucent, click-through preview of where a window will snap. Shown while
/// dragging a window near a screen edge.
final class SnapOverlay {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true          // never interferes with the drag
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        window.contentView = view
    }

    /// Show the overlay at a Cocoa (bottom-left) rect.
    func show(_ cocoaRect: CGRect) {
        window.setFrame(cocoaRect, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
