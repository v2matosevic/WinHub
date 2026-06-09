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

/// One thumbnail cell: image + close button + title, with hover tracking that
/// reveals the close button and brightens the border (taskbar-preview feel).
private final class ThumbCell: NSStackView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Borderless, non-activating floating panel that shows a row of window thumbnails
/// above a Dock tile — the Windows taskbar-preview analogue.
final class DockPreviewPanel: NSPanel {
    var onSelect: ((DockSelection) -> Void)?
    /// The user clicked a thumbnail's ⊗ — close that window.
    var onClose: ((DockSelection) -> Void)?

    private let effect = NSVisualEffectView()
    private let stack = NSStackView()

    // Remembered so the panel can re-anchor after a thumbnail is closed/removed.
    private var anchorTile: CGRect = .zero
    private var anchorOrientation: DockOrientation = .bottom

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

    func show(shots: [WindowShot], app: NSRunningApplication,
              anchorTileFrameCocoa tile: CGRect, orientation: DockOrientation) {
        anchorTile = tile
        anchorOrientation = orientation

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for shot in shots {
            stack.addArrangedSubview(makeThumb(shot, app: app))
        }
        layoutAndPlace()
        orderFrontRegardless()
    }

    /// Size to fit the current thumbnails and anchor relative to the Dock edge:
    /// above (bottom Dock) or beside (left/right).
    private func layoutAndPlace() {
        effect.layoutSubtreeIfNeeded()
        let fitting = effect.fittingSize
        setContentSize(fitting)

        let gap: CGFloat = 8
        var origin: NSPoint
        switch anchorOrientation {
        case .bottom: origin = NSPoint(x: anchorTile.midX - fitting.width / 2, y: anchorTile.maxY + gap)
        case .left:   origin = NSPoint(x: anchorTile.maxX + gap, y: anchorTile.midY - fitting.height / 2)
        case .right:  origin = NSPoint(x: anchorTile.minX - fitting.width - gap, y: anchorTile.midY - fitting.height / 2)
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorTile) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 6, min(origin.x, visible.maxX - fitting.width - 6))
            origin.y = max(visible.minY + 6, min(origin.y, visible.maxY - fitting.height - 6))
        }
        setFrameOrigin(origin)
    }

    // MARK: - Thumbnail view

    private func makeThumb(_ shot: WindowShot, app: NSRunningApplication) -> NSView {
        let aspect = CGFloat(shot.image.width) / CGFloat(max(1, shot.image.height))
        let height: CGFloat = 130
        let width = min(240, max(90, height * aspect))
        let selection = DockSelection(windowID: shot.windowID, title: shot.title, app: app)

        let button = ThumbButton()
        button.selection = selection
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

        // Image area wraps the thumbnail so the ⊗ can float over its top-right corner.
        let imageWrap = NSView()
        imageWrap.translatesAutoresizingMaskIntoConstraints = false
        imageWrap.addSubview(button)

        let close = ThumbButton()
        close.selection = selection
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        close.contentTintColor = .white
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        close.layer?.cornerRadius = 9
        close.target = self
        close.action = #selector(closeClicked(_:))
        close.isHidden = true
        close.translatesAutoresizingMaskIntoConstraints = false
        imageWrap.addSubview(close)

        NSLayoutConstraint.activate([
            imageWrap.widthAnchor.constraint(equalToConstant: width),
            imageWrap.heightAnchor.constraint(equalToConstant: height),
            button.leadingAnchor.constraint(equalTo: imageWrap.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: imageWrap.trailingAnchor),
            button.topAnchor.constraint(equalTo: imageWrap.topAnchor),
            button.bottomAnchor.constraint(equalTo: imageWrap.bottomAnchor),
            close.topAnchor.constraint(equalTo: imageWrap.topAnchor, constant: 5),
            close.trailingAnchor.constraint(equalTo: imageWrap.trailingAnchor, constant: -5),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.heightAnchor.constraint(equalToConstant: 18),
        ])

        let label = NSTextField(labelWithString: shot.title.isEmpty ? (app.localizedName ?? "Window") : shot.title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true

        let column = ThumbCell(views: [imageWrap, label])
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .centerX
        column.onHover = { hovering in
            close.isHidden = !hovering
            button.layer?.borderColor = NSColor.white
                .withAlphaComponent(hovering ? 0.45 : 0.12).cgColor
        }
        return column
    }

    @objc private func thumbClicked(_ sender: ThumbButton) {
        if let selection = sender.selection { onSelect?(selection) }
    }

    @objc private func closeClicked(_ sender: ThumbButton) {
        guard let selection = sender.selection else { return }
        // Drop the cell immediately for feedback; the AX close happens via onClose.
        if let cell = sender.superview?.superview, cell.superview === stack {
            cell.removeFromSuperview()
        }
        if stack.arrangedSubviews.isEmpty {
            orderOut(nil)
        } else {
            layoutAndPlace()
        }
        onClose?(selection)
    }
}
