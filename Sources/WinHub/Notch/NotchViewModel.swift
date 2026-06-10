import AppKit
import SwiftUI

/// Per-window state for the notch UI: closed/open, hover, the active tab, and
/// the geometry the hosting panel needs for hit-testing.
@MainActor
final class NotchViewModel: ObservableObject {
    enum NotchState { case closed, open }
    enum Tab { case home, shelf }

    @Published private(set) var state: NotchState = .closed
    @Published var tab: Tab = .home
    @Published var isHovering = false
    /// While true (drag hovering the shelf, share sheet up) auto-close is refused.
    @Published var holdOpen = false
    /// True while an external drag is over the island (drives the drop glow).
    @Published var isDropTargeted = false

    let closedSize: CGSize
    let media: MediaWatcher
    let shelf: ShelfStore

    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)

    init(closedSize: CGSize, media: MediaWatcher, shelf: ShelfStore) {
        self.closedSize = closedSize
        self.media = media
        self.shelf = shelf
    }

    func open(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        guard state == .closed else { return }
        withAnimation(Self.openSpring) { state = .open }
    }

    func close() {
        guard state == .open, !holdOpen, !shelf.isSharing else { return }
        withAnimation(Self.closeSpring) { state = .closed }
    }

    var showsActivity: Bool {
        NotchSettings.liveActivity && media.isAvailable && media.hasActivity
    }

    /// Closed pill width: the cutout plus the top-corner flares, widened with
    /// two thumbnail "wings" while the music live activity is showing.
    var closedContentWidth: CGFloat {
        guard showsActivity else { return closedSize.width + 12 }
        return closedSize.width + 2 * max(0, closedSize.height - 12) + 20
    }

    /// Hit-test region in the panel content view's bottom-left-origin coords.
    /// Everything outside falls through to the menu bar below.
    var interactiveRect: CGRect {
        let w = NotchGeometry.windowSize.width
        let h = NotchGeometry.windowSize.height
        switch state {
        case .open:
            return CGRect(x: 0, y: h - NotchGeometry.openSize.height,
                          width: w, height: NotchGeometry.openSize.height)
        case .closed:
            let cw = closedContentWidth + 8
            return CGRect(x: (w - cw) / 2, y: h - closedSize.height - 2,
                          width: cw, height: closedSize.height + 2)
        }
    }
}
