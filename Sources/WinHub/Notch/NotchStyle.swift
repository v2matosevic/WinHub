import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Design tokens + reusable pieces for the notch UI. The surface is a Dynamic
/// Island: pure black so it fuses with the cutout, with depth coming from
/// hairlines, ambient artwork light, and motion — not from gray fills.
enum NotchStyle {
    /// Uniform content inset from the island's left/right edges. The shape's
    /// visible body sits `topRadius` (19) inside the frame, so the true margin
    /// from the visible edge is this minus 19 — 44 reads as a 25-pt margin.
    static let insetX: CGFloat = 44
    /// Content inset from the island's bottom edge.
    static let insetBottom: CGFloat = 20
    /// Standard gap between sibling blocks (artwork ↔ text, tiles ↔ tray).
    static let gap: CGFloat = 20

    /// Hairline stroke used on tiles and wells.
    static let hairline = Color.white.opacity(0.10)
    /// Resting fill for interactive tiles.
    static let tileFill = Color.white.opacity(0.055)
    /// Hovered fill for interactive tiles.
    static let tileFillHover = Color.white.opacity(0.12)

    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
}

// MARK: - Button styles

/// iOS-feel transport button: springs down on press, with a soft circular
/// highlight that blooms on hover.
struct TransportButtonStyle: ButtonStyle {
    var diameter: CGFloat = 34
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0))
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Small utility button (gear, clear): dims at rest, brightens on hover,
/// presses with a gentle scale.
struct GlyphButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? NotchStyle.primaryText : NotchStyle.secondaryText)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

// MARK: - Transitions

/// Content swap used inside the island: scale from the top with a blur wash,
/// like iOS Live Activity content changes.
extension AnyTransition {
    static var islandContent: AnyTransition {
        .scale(scale: 0.86, anchor: .top)
            .combined(with: .opacity)
            .combined(with: .modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0)))
    }
}

struct BlurModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

// MARK: - Artwork palette

/// Pulls a single vibrant accent out of album art: downsample, score pixels by
/// chroma × brightness, average the winners, then clamp into a range that
/// reads well on black.
enum ArtworkPalette {
    static func accent(from image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var best: [(score: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = []
        for i in 0..<(side * side) {
            let r = CGFloat(pixels[i * 4]) / 255
            let g = CGFloat(pixels[i * 4 + 1]) / 255
            let b = CGFloat(pixels[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let chroma = maxC - minC
            best.append((score: chroma * maxC, r: r, g: g, b: b))
        }
        best.sort { $0.score > $1.score }
        let top = best.prefix(max(8, best.count / 10))
        guard let first = top.first, first.score > 0.02 else { return nil }
        let n = CGFloat(top.count)
        let avg = top.reduce((r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))) {
            (r: $0.r + $1.r / n, g: $0.g + $1.g / n, b: $0.b + $1.b / n)
        }

        let color = NSColor(red: avg.r, green: avg.g, blue: avg.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        // Punchy but never neon, bright enough to survive on pure black.
        return NSColor(hue: h,
                       saturation: min(0.72, s * 1.35),
                       brightness: max(0.72, min(0.95, v * 1.25)),
                       alpha: 1)
    }
}

// MARK: - Shelf thumbnails

/// QuickLook file thumbnails with an in-memory cache, falling back to the
/// Finder icon while (or if) generation doesn't pan out.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()

    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        if let hit = cached(for: url) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}
