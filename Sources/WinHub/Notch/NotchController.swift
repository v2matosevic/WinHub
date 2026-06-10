import AppKit
import Combine

/// Owns the notch window, follows display changes, and watches for external
/// file drags so the shelf can catch them even while the notch is closed.
@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var viewModel: NotchViewModel?
    private let media = MediaWatcher()
    private let shelf = ShelfStore()
    private let audioLevels = SystemAudioLevels()
    private var visualizerSinks = Set<AnyCancellable>()
    private var visualizerStopTask: Task<Void, Never>?

    private var screenObserver: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragOpened = false

    func start() {
        media.start()
        rebuildPanel()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanel() }
        }
        installDragMonitors()

        // The tap only runs while music actually plays — no playback, no
        // recording indicator, no permission churn.
        media.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncVisualizer() }
            .store(in: &visualizerSinks)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncVisualizer() }
            .store(in: &visualizerSinks)
    }

    func stop() {
        media.stop()
        visualizerSinks.removeAll()
        visualizerStopTask?.cancel()
        visualizerStopTask = nil
        audioLevels.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeDragMonitors()
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
    }

    // MARK: - Real-audio visualizer lifecycle

    private var visualizerWanted: Bool {
        NotchSettings.realVisualizer && NotchSettings.liveActivity
            && media.isAvailable && media.now.playing
    }

    private func syncVisualizer() {
        if visualizerWanted {
            visualizerStopTask?.cancel()
            visualizerStopTask = nil
            audioLevels.start()
        } else if audioLevels.isRunning, visualizerStopTask == nil {
            // Linger through a quick pause/track-skip before tearing the tap down.
            visualizerStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.visualizerStopTask = nil
                if !self.visualizerWanted { self.audioLevels.stop() }
            }
        }
    }

    // MARK: - Window

    private func rebuildPanel() {
        guard let screen = NotchGeometry.targetScreen() else { return }
        let closedSize = NotchGeometry.closedSize(on: screen)
        if let panel, let vm = viewModel, vm.closedSize == closedSize {
            // Same notch hardware — just follow the screen's (possibly new) frame.
            panel.setFrame(NotchGeometry.windowFrame(on: screen), display: true)
            return
        }
        panel?.orderOut(nil)
        let vm = NotchViewModel(closedSize: closedSize, media: media, shelf: shelf,
                                audioLevels: audioLevels)
        viewModel = vm
        let newPanel = NotchPanel(screen: screen, viewModel: vm)
        panel = newPanel
        newPanel.orderFrontRegardless()
    }

    // MARK: - Drag-to-shelf detection

    /// A drag pasteboard change plus the pointer near the notch means someone
    /// is dragging something onto it — pop the shelf open to catch the drop.
    private func installDragMonitors() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.dragMoved() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.dragEnded() }
        }
    }

    private func removeDragMonitors() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil
        upMonitor = nil
    }

    private func dragMoved() {
        guard NotchSettings.shelfEnabled,
              let vm = viewModel, vm.state == .closed else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastDragChangeCount,
              hotRect.contains(NSEvent.mouseLocation),
              pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self], options: nil)
        else { return }
        dragOpened = true
        vm.open(tab: .shelf)
    }

    private func dragEnded() {
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        guard dragOpened, let vm = viewModel else { return }
        dragOpened = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !vm.isHovering && !vm.holdOpen { vm.close() }
        }
    }

    /// The closed pill, generously inflated, in global Cocoa coordinates.
    private var hotRect: CGRect {
        guard let panel, let vm = viewModel else { return .zero }
        let frame = panel.frame
        let width = vm.closedContentWidth + 60
        let height = vm.closedSize.height + 24
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - height,
                      width: width, height: height)
    }
}
