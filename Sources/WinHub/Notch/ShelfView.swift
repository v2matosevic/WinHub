import SwiftUI
import UniformTypeIdentifiers

/// The shelf tab inside the open notch: AirDrop tile + the item tray.
struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 12) {
            airdropTile
            if shelf.items.isEmpty {
                emptyState
            } else {
                itemTray
            }
        }
    }

    private var airdropTile: some View {
        Button {
            shelf.airDrop()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22))
                Text("AirDrop")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(shelf.items.isEmpty ? 0.3 : 0.85))
            .frame(width: 90, height: 90)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(shelf.items.isEmpty)
        .help("AirDrop everything on the shelf")
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.white.opacity(0.2))
            .overlay(
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title3)
                    Text("Drop files, links or text here")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.4))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(shelf.items) { item in
                    ShelfItemView(item: item, shelf: shelf)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Clear") { shelf.clear() }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.trailing, 4)
        }
    }
}

/// One shelf item: icon + name, drag-out, double-click to open, hover ⊗ to remove.
private struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @State private var hovering = false

    var body: some View {
        let url = shelf.url(for: item)
        VStack(spacing: 4) {
            iconView(url: url)
                .frame(width: 42, height: 42)
            Text(shelf.displayName(for: item))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.13 : 0.06)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    shelf.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { dragProvider(url: url) }
        .onTapGesture(count: 2) {
            if let url { NSWorkspace.shared.open(url) }
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
    private func iconView(url: URL?) -> some View {
        switch item.kind {
        case .file:
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .link:
            Image(systemName: "link")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
        case .text:
            Image(systemName: "text.alignleft")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
