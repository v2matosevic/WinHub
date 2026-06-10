import SwiftUI
import UniformTypeIdentifiers

/// The shelf tab inside the open island: AirDrop tile + the item tray.
/// Tiles use real QuickLook thumbnails and lift on hover.
struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel
    var accent: Color

    var body: some View {
        HStack(spacing: NotchStyle.gap) {
            airdropTile
            ZStack {
                if shelf.items.isEmpty {
                    dropZone
                } else {
                    itemTray
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shelf.items)
        }
        .padding(.top, 2)
    }

    // MARK: - AirDrop

    private var airdropTile: some View {
        AirDropTileButton(enabled: !shelf.items.isEmpty) {
            shelf.airDrop()
        }
    }

    // MARK: - Drop zone (empty)

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                vm.isDropTargeted ? accent.opacity(0.9) : Color.white.opacity(0.18),
                style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(vm.isDropTargeted ? accent.opacity(0.10) : Color.white.opacity(0.025))
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(vm.isDropTargeted ? accent : NotchStyle.tertiaryText)
                    Text("Drop files, links or text")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(NotchStyle.secondaryText)
                    Text("Stash here, drag out anywhere")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchStyle.tertiaryText)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: vm.isDropTargeted)
    }

    // MARK: - Items

    private var itemTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiaryText)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.clear() }
                } label: {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(GlyphButtonStyle())
            }
            .padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shelf.items) { item in
                        ShelfItemTile(item: item, shelf: shelf)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(vm.isDropTargeted ? accent.opacity(0.7) : .clear, lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.18), value: vm.isDropTargeted)
    }
}

/// AirDrop launcher: concentric-wave glyph that tints AirDrop-blue on hover.
private struct AirDropTileButton: View {
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    private let airdropBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(hovering && enabled ? airdropBlue : NotchStyle.secondaryText)
                Text("AirDrop")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering && enabled ? NotchStyle.primaryText : NotchStyle.secondaryText)
            }
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hovering && enabled ? airdropBlue.opacity(0.16) : NotchStyle.tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering && enabled ? airdropBlue.opacity(0.55) : NotchStyle.hairline)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help("AirDrop everything on the shelf")
    }
}

/// One shelf item: QuickLook thumbnail (Finder icon fallback) + name.
/// Drag out, double-click to open, hover ⊗ to remove.
private struct ShelfItemTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        let url = shelf.url(for: item)
        VStack(spacing: 5) {
            thumbView(url: url)
                .frame(width: 50, height: 50)
            Text(shelf.displayName(for: item))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(hovering ? NotchStyle.primaryText : NotchStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 70)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? NotchStyle.tileFillHover : NotchStyle.tileFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NotchStyle.hairline)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white.opacity(0.9), Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .shadow(color: .black.opacity(hovering ? 0.4 : 0), radius: 6, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .onDrag { dragProvider(url: url) }
        .onTapGesture(count: 2) {
            if let url { NSWorkspace.shared.open(url) }
        }
        .task(id: item.id) {
            if item.kind == .file, let url {
                thumbnail = await ThumbnailLoader.shared.thumbnail(for: url, side: 50)
            }
        }
        .help(shelf.displayName(for: item))
    }

    private func dragProvider(url: URL?) -> NSItemProvider {
        switch item.kind {
        case .file:
            if let url, let provider = NSItemProvider(contentsOf: url) { return provider }
        case .link:
            if let url { return NSItemProvider(object: url as NSURL) }
        case .text:
            if let text = item.text { return NSItemProvider(object: text as NSString) }
        }
        return NSItemProvider()
    }

    @ViewBuilder
    private func thumbView(url: URL?) -> some View {
        switch item.kind {
        case .file:
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    glyph("doc.fill")
                }
            }
        case .link:
            glyph("link")
        case .text:
            glyph("text.alignleft")
        }
    }

    private func glyph(_ name: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            Image(systemName: name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(NotchStyle.secondaryText)
        }
    }
}
