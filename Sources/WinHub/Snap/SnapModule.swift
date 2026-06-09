import AppKit
import ApplicationServices

/// Windows-style Aero Snap: drag a window to a screen edge to snap it — left/right
/// half, a corner for a quarter, top edge to maximize — or use ⌃⌥ + arrows from the
/// keyboard. A translucent overlay previews the target while you drag; releasing
/// applies it. Dragging a snapped window away restores its pre-snap size (⌃⌥↓ does
/// the same for the focused window).
final class SnapModule: HubModule {
    let id = "window-snap"
    let title = "Snap windows to edges"
    let summary = "Drag to an edge or corner to snap — halves, quarters, top to maximize. ⌃⌥ arrows for keyboard snapping."
    let requiredPermissions: [Permission] = [.accessibility]
    let isAvailable = true
    private(set) var isRunning = false

    private enum Zone {
        case left, right, maximize
        case topLeft, topRight, bottomLeft, bottomRight
        func rect(in visible: CGRect) -> CGRect {
            switch self {
            case .left:        return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
            case .right:       return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
            case .maximize:    return visible
            case .topLeft:     return CGRect(x: visible.minX, y: visible.midY, width: visible.width / 2, height: visible.height / 2)
            case .topRight:    return CGRect(x: visible.midX, y: visible.midY, width: visible.width / 2, height: visible.height / 2)
            case .bottomLeft:  return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
            case .bottomRight: return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
            }
        }
    }

    /// A window WinHub snapped, with the frame it had before — so dragging it away
    /// (or ⌃⌥↓) can restore it. All frames are Cocoa (bottom-left) coordinates.
    private struct SnapRecord {
        let window: AXUIElement
        var originalFrame: CGRect
        var snappedFrame: CGRect
    }

    private let overlay = SnapOverlay()
    private let hotkeys = SnapHotkeys()
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var dragSessionActive = false
    private var draggedWindow: AXUIElement?
    private var dragStartFrame: CGRect?      // Cocoa; also serves as the move-detection baseline
    private var isMoving = false
    private var pendingTarget: CGRect?
    private var lastTrackTime: TimeInterval = 0

    private var snapRecords: [SnapRecord] = []

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        // Drag-driven: plain clicks cost nothing — the AX hit-test happens once, on
        // the first dragged event of a drag session, and tracking rides the dragged
        // events themselves (throttled to ~20 Hz) instead of a timer.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in self?.dragged() }
        upMonitor   = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp])      { [weak self] _ in self?.end() }
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.register()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        [dragMonitor, upMonitor].forEach { if let monitor = $0 { NSEvent.removeMonitor(monitor) } }
        dragMonitor = nil
        upMonitor = nil
        hotkeys.unregister()
        snapRecords.removeAll()
        reset()
    }

    // MARK: - Drag tracking

    private func dragged() {
        if !dragSessionActive {
            dragSessionActive = true
            let topLeft = ScreenGeometry.topLeftPoint(fromCocoa: NSEvent.mouseLocation)
            if let window = WindowAX.window(atTopLeft: topLeft), let frame = WindowAX.frame(of: window) {
                draggedWindow = window
                dragStartFrame = ScreenGeometry.cocoaRect(fromAX: frame)
            }
        }
        guard draggedWindow != nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTrackTime >= 0.05 else { return }
        lastTrackTime = now
        track()
    }

    private func track() {
        guard let window = draggedWindow else { return }

        // Engage only once the window is actually moving — not on an in-window drag
        // (text selection), where the window frame doesn't move.
        if !isMoving {
            guard let start = dragStartFrame, let now = WindowAX.position(of: window),
                  hypot(now.x - ScreenGeometry.axRect(fromCocoa: start).minX,
                        now.y - ScreenGeometry.axRect(fromCocoa: start).minY) > 8 else { return }
            isMoving = true
        }

        let cocoa = NSEvent.mouseLocation
        guard let screen = ScreenGeometry.screen(containing: cocoa) else {
            pendingTarget = nil; overlay.hide(); return
        }

        if let zone = zone(forCursor: cocoa, on: screen) {
            let target = zone.rect(in: screen.visibleFrame)
            pendingTarget = target
            overlay.show(target)
        } else {
            pendingTarget = nil
            overlay.hide()
        }
    }

    private func end() {
        if isMoving, let window = draggedWindow, let start = dragStartFrame {
            if let target = pendingTarget {
                noteSnap(of: window, from: start, to: target)
                WindowAX.setFrame(window, cocoaRect: target)
            } else if let index = recordIndex(for: window) {
                // Dragged a snapped window away from its snapped frame → restore its
                // pre-snap size at the drop point (the missing half of Aero Snap). A
                // mismatched start frame means the user re-placed it some other way —
                // the record is stale either way.
                if approxEqual(start, snapRecords[index].snappedFrame) {
                    restoreSize(window, to: snapRecords[index].originalFrame.size)
                }
                snapRecords.remove(at: index)
            }
        }
        reset()
    }

    private func reset() {
        overlay.hide()
        dragSessionActive = false
        draggedWindow = nil
        dragStartFrame = nil
        isMoving = false
        pendingTarget = nil
    }

    // MARK: - Keyboard snapping

    private func perform(_ action: SnapHotkeys.Action) {
        guard isRunning,
              let window = WindowAX.focusedWindow(),
              let axFrame = WindowAX.frame(of: window) else { return }
        let current = ScreenGeometry.cocoaRect(fromAX: axFrame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) ?? NSScreen.main
        else { return }

        let zone: Zone
        switch action {
        case .left:     zone = .left
        case .right:    zone = .right
        case .maximize: zone = .maximize
        case .restore:
            if let index = recordIndex(for: window) {
                if approxEqual(current, snapRecords[index].snappedFrame) {
                    WindowAX.setFrame(window, cocoaRect: snapRecords[index].originalFrame)
                }
                snapRecords.remove(at: index)
            }
            return
        }

        let target = zone.rect(in: screen.visibleFrame)
        noteSnap(of: window, from: current, to: target)
        WindowAX.setFrame(window, cocoaRect: target)
    }

    // MARK: - Snap registry

    private func recordIndex(for window: AXUIElement) -> Int? {
        snapRecords.firstIndex { CFEqual($0.window, window) }
    }

    private func noteSnap(of window: AXUIElement, from current: CGRect, to target: CGRect) {
        if let index = recordIndex(for: window) {
            // Re-snapping zone-to-zone keeps the true original; a frame that no longer
            // matches the recorded snap means the user re-placed the window manually,
            // so the current frame becomes the new original.
            if !approxEqual(current, snapRecords[index].snappedFrame) {
                snapRecords[index].originalFrame = current
            }
            snapRecords[index].snappedFrame = target
        } else {
            snapRecords.append(SnapRecord(window: window, originalFrame: current, snappedFrame: target))
            if snapRecords.count > 32 { snapRecords.removeFirst() }   // stale-window cap
        }
    }

    /// Restore a window to `size`, keeping its title bar where the user dropped it
    /// and the cursor over the window (so the drop never strands the pointer).
    private func restoreSize(_ window: AXUIElement, to size: CGSize) {
        guard let axFrame = WindowAX.frame(of: window) else { return }
        let current = ScreenGeometry.cocoaRect(fromAX: axFrame)
        var origin = CGPoint(x: current.minX, y: current.maxY - size.height)
        let cursor = NSEvent.mouseLocation
        if cursor.x < origin.x + 40 || cursor.x > origin.x + size.width - 40 {
            origin.x = cursor.x - size.width / 2
        }
        WindowAX.setFrame(window, cocoaRect: CGRect(origin: origin, size: size))
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance &&
        abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    // MARK: - Zones

    private func zone(forCursor point: CGPoint, on screen: NSScreen) -> Zone? {
        let frame = screen.frame
        let threshold: CGFloat = 6
        let corner: CGFloat = 120
        // Only a true outer edge counts: at a seam between two displays the cursor is
        // just crossing over, and snapping there is a misfire.
        if point.x <= frame.minX + threshold,
           !hasScreen(beyond: CGPoint(x: frame.minX - 8, y: point.y)) {
            if point.y >= frame.maxY - corner { return .topLeft }
            if point.y <= frame.minY + corner { return .bottomLeft }
            return .left
        }
        if point.x >= frame.maxX - threshold,
           !hasScreen(beyond: CGPoint(x: frame.maxX + 8, y: point.y)) {
            if point.y >= frame.maxY - corner { return .topRight }
            if point.y <= frame.minY + corner { return .bottomRight }
            return .right
        }
        if point.y >= frame.maxY - threshold,                            // top edge (high y in Cocoa)
           !hasScreen(beyond: CGPoint(x: point.x, y: frame.maxY + 8)) { return .maximize }
        return nil
    }

    private func hasScreen(beyond point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) }
    }
}
