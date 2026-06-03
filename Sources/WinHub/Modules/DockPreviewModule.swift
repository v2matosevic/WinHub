import AppKit
import ApplicationServices

/// The headline feature: hover a Dock icon → live window thumbnails (Windows
/// taskbar style). Polls the cursor position, hit-tests the Dock via Accessibility,
/// captures the hovered app's windows via ScreenCaptureKit, and shows them in a
/// floating panel. Clicking a thumbnail raises that window.
final class DockPreviewModule: HubModule {
    let id = "dock-preview"
    let title = "Dock hover previews"
    let summary = "Window thumbnails when you hover a Dock icon."
    let requiredPermissions: [Permission] = [.accessibility, .screenRecording]
    let isAvailable = true
    private(set) var isRunning = false

    private let panel = DockPreviewPanel()
    private let thumbnails = WindowThumbnailService()
    private var pollTimer: Timer?

    private var currentApp: NSRunningApplication?
    private var pendingHide = false
    private var generation = 0

    func start() {
        let ax = Permission.accessibility.isGranted
        let sr = Permission.screenRecording.isGranted
        guard !isRunning, ax, sr else {
            NSLog("[WinHub.dock] start skipped — running=\(isRunning) accessibility=\(ax) screenRecording=\(sr)")
            return
        }
        isRunning = true
        NSLog("[WinHub.dock] started — polling for Dock hovers")

        panel.onSelect = { [weak self] selection in self?.select(selection) }

        // Poll the cursor instead of an event monitor: reading the cursor location
        // needs no extra permission, and ~16 fps is plenty for hover detection.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        generation += 1
        currentApp = nil
        pendingHide = false
        panel.orderOut(nil)
    }

    // MARK: - Hover loop

    private func tick() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let cocoa = DockAccessibility.cocoaPoint(fromTopLeft: location)

        // Over the panel itself? Keep it open.
        if panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(cocoa) {
            pendingHide = false
            return
        }

        if let tile = DockAccessibility.tile(atTopLeft: location),
           let app = tile.runningApp, app.activationPolicy == .regular {
            pendingHide = false
            if app.processIdentifier != currentApp?.processIdentifier {
                showPreview(for: app, tile: tile)
            }
        } else if currentApp != nil || panel.isVisible {
            requestHide()
        }
    }

    private func showPreview(for app: NSRunningApplication, tile: DockAccessibility.Tile) {
        generation += 1
        let token = generation
        currentApp = app
        pendingHide = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)   // hover dwell
            guard token == self.generation else { return }

            var shots = await self.thumbnails.capture(appPID: app.processIdentifier)

            // Add minimized windows (icon placeholders — macOS can't live-capture them).
            let minimized = DockAccessibility.minimizedWindowTitles(forPID: app.processIdentifier)
            if !minimized.isEmpty, let icon = app.icon?.cgImageRep() {
                let shown = Set(shots.map { $0.title })
                for title in minimized where !shown.contains(title) {
                    shots.append(WindowShot(windowID: 0,
                                            title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                                            image: icon))
                }
            }

            guard token == self.generation else { return }
            if shots.isEmpty {
                self.panel.orderOut(nil)
            } else {
                self.panel.show(shots: shots, app: app,
                                anchorTileFrameCocoa: tile.frameCocoa, orientation: tile.orientation)
            }
        }
    }

    private func requestHide() {
        guard !pendingHide else { return }
        pendingHide = true
        generation += 1
        let token = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard self.pendingHide, token == self.generation else { return }
            self.panel.orderOut(nil)
            self.currentApp = nil
            self.pendingHide = false
        }
    }

    // MARK: - Raising a window

    private func select(_ selection: DockSelection) {
        panel.orderOut(nil)
        currentApp = nil
        pendingHide = false

        let app = selection.app
        app.activate()

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }

        // Match by title; fall back to the first window.
        let match = windows.first { window in
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            return (titleValue as? String) == selection.title
        } ?? windows.first

        if let match {
            // Un-minimize first (no-op if it wasn't), then raise and focus.
            AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, match)
        }
    }
}
