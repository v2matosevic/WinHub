import SwiftUI
import UniformTypeIdentifiers

/// The notch UI: a black pill matching the camera cutout when closed (with a
/// music live activity inline), expanding into a media-player + shelf hub.
struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaWatcher
    @ObservedObject var shelf: ShelfStore

    @Namespace private var artworkSpace
    @State private var hoverTask: Task<Void, Never>?
    @State private var dropTargeted = false

    private var isOpen: Bool { vm.state == .open }

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
                .fill(Color.black)
                .shadow(color: .black.opacity(isOpen || vm.isHovering ? 0.55 : 0),
                        radius: isOpen ? 10 : 5, y: 3)
            if isOpen {
                openContent
                    .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            } else {
                closedContent
            }
        }
        .frame(width: isOpen ? NotchGeometry.openSize.width : vm.closedContentWidth,
               height: isOpen ? NotchGeometry.openSize.height : vm.closedSize.height)
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
            if targeted {
                vm.holdOpen = true
                vm.open(tab: .shelf)
            } else {
                vm.holdOpen = false
                closeSoonUnlessHovered()
            }
        }
        .animation(isOpen ? NotchViewModel.openSpring : NotchViewModel.closeSpring, value: isOpen)
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
                artworkView(side: side, cornerRadius: 4)
                    .padding(.leading, 7)
                Spacer(minLength: 0)
                AudioBarsView(playing: media.now.playing)
                    .frame(width: side, height: max(8, side * 0.55))
                    .padding(.trailing, 9)
            }
            .frame(width: vm.closedContentWidth, height: vm.closedSize.height)
        }
    }

    // MARK: - Open (hub)

    private var openContent: some View {
        VStack(spacing: 4) {
            header
            Group {
                switch vm.tab {
                case .home: playerView
                case .shelf: ShelfView(shelf: shelf, vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: NotchGeometry.openSize.width, height: NotchGeometry.openSize.height)
    }

    /// Top strip: tabs on the left, status on the right — the middle stays
    /// clear so the physical cutout blends into the black background.
    private var header: some View {
        HStack {
            if NotchSettings.shelfEnabled {
                HStack(spacing: 2) {
                    tabButton("music.note", tab: .home, help: "Now playing")
                    tabButton("tray.fill", tab: .shelf, help: "Shelf")
                }
                .padding(2)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            Spacer()
            if !media.isAvailable {
                Image(systemName: "play.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Media controls are unavailable on this system")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: max(26, vm.closedSize.height))
        .padding(.top, 2)
    }

    private func tabButton(_ symbol: String, tab: NotchViewModel.Tab, help: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { vm.tab = tab }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(vm.tab == tab ? .white : .white.opacity(0.45))
                .frame(width: 34, height: 20)
                .background(Capsule().fill(.white.opacity(vm.tab == tab ? 0.18 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Player

    private var playerView: some View {
        HStack(spacing: 16) {
            artworkView(side: 92, cornerRadius: 12)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(media.now.title ?? (media.isAvailable ? "Nothing playing" : "Media unavailable"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media.now.artist ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                ProgressSliderView(media: media)
                    .padding(.top, 2)
                controls
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            controlButton("backward.fill", size: 14) { media.send(.previousTrack) }
            controlButton(media.now.playing ? "pause.fill" : "play.fill", size: 20) {
                media.send(.togglePlayPause)
            }
            controlButton("forward.fill", size: 14) { media.send(.nextTrack) }
        }
        .frame(maxWidth: .infinity)
        .disabled(!media.isAvailable)
        .opacity(media.isAvailable ? 1 : 0.4)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .matchedGeometryEffect(id: "artwork", in: artworkSpace)
    }
}

// MARK: - Progress slider

/// Thin scrubber with live playhead extrapolation (no polling of the adapter —
/// elapsed + rate × wall-clock since the last sample).
private struct ProgressSliderView: View {
    @ObservedObject var media: MediaWatcher
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = media.now.duration ?? 0
            let elapsed = scrubbing ? scrubValue : (media.now.estimatedElapsed(at: context.date) ?? 0)
            VStack(spacing: 2) {
                GeometryReader { geo in
                    let frac = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: max(4, geo.size.width * frac))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
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
                HStack {
                    Text(Self.timeString(elapsed))
                    Spacer()
                    Text(Self.timeString(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
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

// MARK: - Closed-notch visualizer

/// Four bouncing bars beside the cutout while music plays. Decorative, not a
/// real spectrum — deterministic pseudo-random heights per tick.
struct AudioBarsView: View {
    var playing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.35)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { bar in
                    let h = playing ? Self.height(tick: tick, bar: bar) : 0.15
                    Capsule()
                        .fill(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(y: h, anchor: .bottom)
                        .animation(.easeInOut(duration: 0.3), value: h)
                }
            }
        }
    }

    private static func height(tick: Int, bar: Int) -> CGFloat {
        let v = abs(sin(Double(tick &* 7 &+ bar &* 13) * 43758.5453)
            .truncatingRemainder(dividingBy: 1))
        return 0.3 + 0.7 * CGFloat(v)
    }
}
