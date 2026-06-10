import AppKit
import SwiftUI

/// Click-through container: only the region the view-model declares
/// interactive receives events; everything else falls through to the menu bar
/// beneath the (mostly transparent) panel.
private final class PassThroughView: NSView {
    weak var viewModel: NotchViewModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let viewModel, viewModel.interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Borderless, non-activating panel pinned over the notch on every Space,
/// above the menu bar, dark regardless of system appearance.
final class NotchPanel: NSPanel {
    init(screen: NSScreen, viewModel: NotchViewModel) {
        super.init(contentRect: NotchGeometry.windowFrame(on: screen),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        // Above the menu bar so the pill can cover the cutout edge-to-edge.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        acceptsMouseMovedEvents = true

        let container = PassThroughView(frame: NSRect(origin: .zero, size: NotchGeometry.windowSize))
        container.viewModel = viewModel
        let hosting = NSHostingView(rootView: NotchRootView(
            vm: viewModel, media: viewModel.media, shelf: viewModel.shelf))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
