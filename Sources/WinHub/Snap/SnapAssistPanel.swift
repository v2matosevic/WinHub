import AppKit

/// An NSButton that carries the index of the shot it represents.
private final class AssistThumbButton: NSButton {
    var index = 0
}

/// The Snap Assist picker: fills the empty half of the screen after a half-snap
/// with thumbnails of the other open windows. Click one — or arrow to it and press
/// Return — to snap it into that half. Esc, any other key, or a click elsewhere
/// dismisses it.
///
/// Non-activating so the just-snapped app stays frontmost, but key so arrows and
/// Return land here without an event tap.
final class SnapAssistPanel: NSPanel {
    var onPick: ((WindowShot) -> Void)?
    var onCancel: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let grid = NSStackView()
    private var buttons: [AssistThumbButton] = []
    private var shots: [WindowShot] = []
    private var columns = 1
    private var selected = 0 { didSet { updateSelection() } }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 20
        grid.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    /// Show the picker covering `zone` (a Cocoa rect — the empty half, inset a
    /// little so the snapped window's edge stays visible).
    func show(_ shots: [WindowShot], zone: CGRect) {
        self.shots = shots
        columns = shots.count > 1 ? 2 : 1
        buildGrid(fitting: zone.insetBy(dx: 48, dy: 48).size)
        selected = 0

        setFrame(zone.insetBy(dx: 10, dy: 10), display: true)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
        shots = []
        buttons = []
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: move(by: -1)              // ←
        case 124: move(by: 1)               // →
        case 126: move(by: -columns)        // ↑
        case 125: move(by: columns)         // ↓
        case 36, 76, 49:                    // Return, keypad Enter, Space
            if shots.indices.contains(selected) { onPick?(shots[selected]) }
        default:                            // Esc or any other key: get out of the way
            onCancel?()
        }
    }

    private func move(by delta: Int) {
        let target = selected + delta
        if shots.indices.contains(target) { selected = target }
    }

    private func updateSelection() {
        for button in buttons {
            let isSelected = button.index == selected
            button.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.12).cgColor
            button.layer?.borderWidth = isSelected ? 3 : 1
        }
    }

    // MARK: - Grid

    private func buildGrid(fitting available: CGSize) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []

        // Cell width honors both the column budget and the row-height budget
        // (image is ~0.62× the width, plus a 26 pt title line under it).
        let rows = (shots.count + columns - 1) / columns
        let spacing: CGFloat = 20
        let widthBudget = (available.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let heightBudget = ((available.height - CGFloat(rows - 1) * spacing) / CGFloat(rows) - 26) / 0.62
        let cellWidth = min(300, widthBudget, heightBudget)
        let imageHeight = cellWidth * 0.62

        for rowStart in stride(from: 0, to: shots.count, by: columns) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = spacing
            row.alignment = .top
            for index in rowStart..<min(rowStart + columns, shots.count) {
                row.addArrangedSubview(makeCell(index: index, width: cellWidth, imageHeight: imageHeight))
            }
            grid.addArrangedSubview(row)
        }
    }

    private func makeCell(index: Int, width: CGFloat, imageHeight: CGFloat) -> NSView {
        let shot = shots[index]

        let button = AssistThumbButton()
        button.index = index
        button.image = NSImage(cgImage: shot.image,
                               size: NSSize(width: shot.image.width, height: shot.image.height))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.target = self
        button.action = #selector(thumbClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: imageHeight).isActive = true
        buttons.append(button)

        let app = NSRunningApplication(processIdentifier: shot.ownerPID)
        let label = NSTextField(labelWithString: shot.title.isEmpty
            ? (app?.localizedName ?? "Window") : shot.title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = NSStackView()
        caption.orientation = .horizontal
        caption.spacing = 5
        if let icon = app?.icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
            caption.addArrangedSubview(iconView)
        }
        caption.addArrangedSubview(label)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true

        let column = NSStackView(views: [button, caption])
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .centerX
        return column
    }

    @objc private func thumbClicked(_ sender: AssistThumbButton) {
        if shots.indices.contains(sender.index) { onPick?(shots[sender.index]) }
    }
}
