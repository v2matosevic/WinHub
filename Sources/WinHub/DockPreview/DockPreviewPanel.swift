import AppKit

/// What the user clicked: enough to raise the right window of the right app.
struct DockSelection {
    let windowID: CGWindowID
    let title: String
    let app: NSRunningApplication
}

/// An NSButton that carries the window it represents.
private final class ThumbButton: NSButton {
    var selection: DockSelection?
}

/// Borderless, non-activating floating panel that shows a row of window thumbnails
/// above a Dock tile — the Windows taskbar-preview analogue.
final class DockPreviewPanel: NSPanel {
    var onSelect: ((DockSelection) -> Void)?

    private let effect = NSVisualEffectView()
    private let stack = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(shots: [WindowShot], app: NSRunningApplication, anchorTileFrameCocoa tile: CGRect) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for shot in shots {
            stack.addArrangedSubview(makeThumb(shot, app: app))
        }
        effect.layoutSubtreeIfNeeded()

        let fitting = effect.fittingSize
        setContentSize(fitting)

        var origin = NSPoint(x: tile.midX - fitting.width / 2, y: tile.maxY + 8)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(tile) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 6, min(origin.x, visible.maxX - fitting.width - 6))
            origin.y = min(origin.y, visible.maxY - fitting.height - 6)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    // MARK: - Thumbnail view

    private func makeThumb(_ shot: WindowShot, app: NSRunningApplication) -> NSView {
        let aspect = CGFloat(shot.image.width) / CGFloat(max(1, shot.image.height))
        let height: CGFloat = 130
        let width = min(240, max(90, height * aspect))

        let button = ThumbButton()
        button.selection = DockSelection(windowID: shot.windowID, title: shot.title, app: app)
        button.image = NSImage(cgImage: shot.image,
                               size: NSSize(width: shot.image.width, height: shot.image.height))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.target = self
        button.action = #selector(thumbClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true

        let label = NSTextField(labelWithString: shot.title.isEmpty ? (app.localizedName ?? "Window") : shot.title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true

        let column = NSStackView(views: [button, label])
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .centerX
        return column
    }

    @objc private func thumbClicked(_ sender: ThumbButton) {
        if let selection = sender.selection { onSelect?(selection) }
    }
}
