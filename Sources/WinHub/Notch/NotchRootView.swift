import SwiftUI
import UniformTypeIdentifiers

/// The notch UI: a black island fused with the camera cutout when closed
/// (music live activity inline), expanding into a media + shelf hub. Depth
/// comes from artwork-driven ambient light, hairlines and motion — the
/// surface itself stays pure black, like the Dynamic Island.
struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaWatcher
    @ObservedObject var shelf: ShelfStore

    @Namespace private var artworkSpace
    @Namespace private var tabSpace
    @State private var hoverTask: Task<Void, Never>?
    @State private var dropTargeted = false

    private var isOpen: Bool { vm.state == .open }
    private var accent: Color { media.accent.map(Color.init(nsColor:)) ?? .white }

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(width: NotchGeometry.windowSize.width,
               height: NotchGeometry.windowSize.height,
               alignment: .top)
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: isOpen ? 19 : 6, bottomRadius: isOpen ? 24 : 14)
                .fill(.black)
                .shadow(color: .black.opacity(isOpen ? 0.55 : vm.isHovering ? 0.35 : 0),
                        radius: isOpen ? 12 : 5, y: 3)
            // Specular hairline along the open island's bottom edge — the
            // "machined edge" that separates it from whatever is behind.
            if isOpen {
                NotchShape(topRadius: 19, bottomRadius: 24)
                    .stroke(
                        LinearGradient(
                            colors: [.clear, .clear, .white.opacity(0.14)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                    .padding(0.5)
            }
            if isOpen {
                openContent
                    .transition(.islandContent)
            } else {
                closedContent
            }
        }
        .frame(width: isOpen ? NotchGeometry.openSize.width : vm.closedContentWidth,
               height: isOpen ? NotchGeometry.openSize.height : vm.closedSize.height)
        .scaleEffect(vm.isHovering && !isOpen ? 1.035 : 1, anchor: .top)
        .contentShape(Rectangle())
        .onHover(perform: handleHover)
        .onTapGesture { if !isOpen { vm.open() } }
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText],
                isTargeted: $dropTargeted) { providers in
            guard NotchSettings.shelfEnabled else { return false }
            return shelf.handleDrop(providers)
        }
        .onChange(of: dropTargeted) { _, targeted in
            guard NotchSettings.shelfEnabled else { return }
            vm.isDropTargeted = targeted
            if targeted {
                vm.holdOpen = true
                vm.open(tab: .shelf)
            } else {
                vm.holdOpen = false
                closeSoonUnlessHovered()
            }
        }
        .animation(isOpen ? NotchViewModel.openSpring : NotchViewModel.closeSpring, value: isOpen)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: vm.isHovering)
        .animation(.smooth(duration: 0.25), value: vm.closedContentWidth)
    }

    // MARK: - Hover state machine

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            vm.isHovering = true
            guard !isOpen else { return }
            if NotchSettings.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
            guard NotchSettings.openOnHover else { return }
            let delay = NotchSettings.hoverDelay
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled, vm.isHovering, vm.state == .closed else { return }
                vm.open()
            }
        } else {
            // Small debounce so skimming the edge doesn't slam it shut.
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                vm.isHovering = false
                if vm.state == .open { vm.close() }
            }
        }
    }

    private func closeSoonUnlessHovered() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !vm.isHovering && !vm.holdOpen { vm.close() }
        }
    }

    // MARK: - Closed (live activity)

    @ViewBuilder private var closedContent: some View {
        if vm.showsActivity {
            let side = max(0, vm.closedSize.height - 12)
            HStack(spacing: 0) {
                artworkView(side: side, cornerRadius: 4.5)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
                EqualizerView(playing: media.now.playing, tint: accent)
                    .frame(width: side - 2, height: max(10, side * 0.52))
                    .padding(.trailing, 15)
            }
            .frame(width: vm.closedContentWidth, height: vm.closedSize.height)
        }
    }

    // MARK: - Open (hub)

    private var openContent: some View {
        VStack(spacing: 2) {
            header
            Group {
                switch vm.tab {
                case .home:
                    playerView
                        .transition(.islandContent)
                case .shelf:
                    ShelfView(shelf: shelf, vm: vm, accent: accent)
                        .transition(.islandContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, NotchStyle.insetX)
            .padding(.bottom, NotchStyle.insetBottom)
        }
        .frame(width: NotchGeometry.openSize.width, height: NotchGeometry.openSize.height)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: vm.tab)
    }

    /// Top strip: tabs left, utilities right — the middle stays clear so the
    /// physical cutout disappears into the black.
    private var header: some View {
        HStack(spacing: 0) {
            if NotchSettings.shelfEnabled {
                tabPicker
            }
            Spacer()
            if !media.isAvailable {
                Image(systemName: "play.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiaryText)
                    .help("Media controls are unavailable on this system")
                    .padding(.trailing, 10)
            }
            Button {
                NotificationCenter.default.post(name: .winhubOpenPreferences, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("WinHub Settings")
        }
        .padding(.horizontal, NotchStyle.insetX - 3)  // pill/glyph chrome adds ~3pt optically
        .frame(height: max(28, vm.closedSize.height))
        .padding(.top, 3)
    }

    private var tabPicker: some View {
        HStack(spacing: 2) {
            tabButton("music.note", tab: .home, help: "Now playing")
            tabButton("tray.fill", tab: .shelf, help: "Shelf")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }

    private func tabButton(_ symbol: String, tab: NotchViewModel.Tab, help: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { vm.tab = tab }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(vm.tab == tab ? Color.black : NotchStyle.secondaryText)
                .frame(width: 36, height: 19)
                .background {
                    if vm.tab == tab {
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .matchedGeometryEffect(id: "tab-selection", in: tabSpace)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Player

    @ViewBuilder private var playerView: some View {
        if media.now.title == nil {
            idleView
        } else {
            HStack(spacing: NotchStyle.gap + 2) {
                artworkView(side: 100, cornerRadius: 14)
                    .background(ambientGlow)
                    .overlay(alignment: .bottomTrailing) { sourceBadge }
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.now.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NotchStyle.primaryText)
                        .lineLimit(1)
                    Text(media.now.artist ?? " ")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchStyle.secondaryText)
                        .lineLimit(1)
                    ScrubberView(media: media, accent: accent)
                        .padding(.top, 6)
                    transportControls
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
    }

    /// Soft, oversized blur of the artwork itself — ambient light spilling
    /// out of the cover, the way iOS does it on the Lock Screen player.
    @ViewBuilder private var ambientGlow: some View {
        if let art = media.artwork {
            Image(nsImage: art)
                .resizable()
                .scaleEffect(1.3)
                .blur(radius: 32)
                .saturation(1.6)
                .opacity(0.55)
        }
    }

    @ViewBuilder private var sourceBadge: some View {
        if let icon = media.sourceAppIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                .offset(x: 7, y: 7)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
            Button { media.send(.previousTrack) } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NotchStyle.primaryText)
            }
            .buttonStyle(TransportButtonStyle(diameter: 32))
            Button { media.send(.togglePlayPause) } label: {
                Image(systemName: media.now.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(NotchStyle.primaryText)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .buttonStyle(TransportButtonStyle(diameter: 40))
            Button { media.send(.nextTrack) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NotchStyle.primaryText)
            }
            .buttonStyle(TransportButtonStyle(diameter: 32))
        }
        .frame(maxWidth: .infinity)
        .disabled(!media.isAvailable)
        .opacity(media.isAvailable ? 1 : 0.35)
    }

    private var idleView: some View {
        HStack(spacing: NotchStyle.gap + 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(NotchStyle.tileFill)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(NotchStyle.hairline)
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(NotchStyle.tertiaryText)
            }
            .frame(width: 100, height: 100)
            VStack(alignment: .leading, spacing: 4) {
                Text(media.isAvailable ? "Nothing playing" : "Media unavailable")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchStyle.primaryText)
                Text(media.isAvailable
                     ? "Play something — it'll show up here with full controls."
                     : "This system blocks now-playing access.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    // MARK: - Shared artwork

    private func artworkView(side: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let art = media.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(NotchStyle.tileFill)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.38))
                        .foregroundStyle(NotchStyle.tertiaryText)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .matchedGeometryEffect(id: "artwork", in: artworkSpace)
    }
}

// MARK: - Scrubber

/// iOS-Music-style scrubber: knobless capsule that thickens under the pointer,
/// tinted from the artwork, with elapsed / −remaining at the ends.
private struct ScrubberView: View {
    @ObservedObject var media: MediaWatcher
    var accent: Color
    @State private var hovering = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = media.now.duration ?? 0
            let elapsed = scrubbing ? scrubValue : (media.now.estimatedElapsed(at: context.date) ?? 0)
            let active = hovering || scrubbing
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let frac = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.9), accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(5, geo.size.width * frac))
                    }
                    .frame(height: active ? 8 : 4.5)
                    .frame(maxHeight: .infinity)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                scrubbing = true
                                scrubValue = duration * min(1, max(0, value.location.x / geo.size.width))
                            }
                            .onEnded { _ in
                                guard scrubbing else { return }
                                media.seek(to: scrubValue)
                                scrubbing = false
                            }
                    )
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                HStack {
                    Text(Self.timeString(elapsed))
                    Spacer()
                    Text(duration > 0 ? "−" + Self.timeString(max(0, duration - elapsed)) : "--:--")
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(NotchStyle.tertiaryText)
            }
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Closed-notch equalizer

/// Now-Playing bars beside the cutout, tinted from the artwork. Driven by
/// layered sines per bar — continuous, organic motion like Apple's own
/// Now Playing indicator, never the random jump of a tick-based fake.
/// (A true spectrum would need a system audio tap + capture permission.)
struct EqualizerView: View {
    var playing: Bool
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { bar in
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(y: playing ? Self.level(t, bar) : 0.22, anchor: .bottom)
                        .animation(.easeOut(duration: 0.4), value: playing)
                }
            }
        }
    }

    /// Three detuned sines per bar; neighbouring bars are phase-shifted so
    /// the group undulates instead of moving in lockstep.
    private static func level(_ t: Double, _ bar: Int) -> CGFloat {
        let phase = Double(bar) * 1.7
        let v = sin(t * 4.1 + phase) * 0.45
            + sin(t * 6.7 + phase * 2.3) * 0.35
            + sin(t * 2.3 + phase * 0.7) * 0.20
        return CGFloat(0.30 + 0.68 * abs(v))
    }
}

extension Notification.Name {
    /// Posted by notch UI; AppDelegate opens the Settings window.
    static let winhubOpenPreferences = Notification.Name("winhub.openPreferences")
}
