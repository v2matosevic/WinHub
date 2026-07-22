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
    let summary = "Drag to an edge or corner to snap — halves, quarters, top to maximize. ⌃⌥ arrows for keyboard snapping. After a half-snap, pick a window to fill the other half."
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
    private let assist = SnapAssist()
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var dragSessionActive = false
    private var draggedWindow: AXUIElement?
    private var dragStartFrame: CGRect?      // Cocoa; also serves as the move-detection baseline
    private var isMoving = false
    private var pendingTarget: CGRect?
    private var pendingZone: Zone?
    private var pendingVisible: CGRect?
    private var lastTrackTime: TimeInterval = 0

    private var snapRecords: [SnapRecord] = []

    /// One Snap Assist chain: the empty zones still to fill (a half leaves one, a
    /// quarter leaves its sibling quarter then the opposite half — the Windows
    /// build-a-layout flow) and the windows already placed, excluded from later
    /// pickers.
    private struct AssistSession {
        var pendingZones: [CGRect]
        var exclusions: [(pid: pid_t, title: String)]
    }
    private var assistSession: AssistSession?

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
        // Snap Assist picks route back here so they land in the snap registry like
        // any other snap (⌃⌥↓ and drag-away restore keep working on them).
        assist.onPick = { [weak self] window, target in
            guard let self, let axFrame = WindowAX.frame(of: window) else { return }
            let current = ScreenGeometry.cocoaRect(fromAX: axFrame)
            self.noteSnap(of: window, from: current, to: target)
            WindowAX.setFrame(window, cocoaRect: target)
            self.advanceAssist(afterPlacing: window)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        [dragMonitor, upMonitor].forEach { if let monitor = $0 { NSEvent.removeMonitor(monitor) } }
        dragMonitor = nil
        upMonitor = nil
        hotkeys.unregister()
        assist.dismiss()
        snapRecords.removeAll()
        reset()
    }

    // MARK: - Drag tracking

    private func dragged() {
        if !dragSessionActive {
            dragSessionActive = true
            assist.dismiss()     // grabbing a window means the user moved on
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
            pendingZone = zone
            pendingVisible = screen.visibleFrame
            overlay.show(target)
        } else {
            pendingTarget = nil
            pendingZone = nil
            pendingVisible = nil
            overlay.hide()
        }
    }

    private func end() {
        if isMoving, let window = draggedWindow, let start = dragStartFrame {
            if let target = pendingTarget {
                noteSnap(of: window, from: start, to: target)
                WindowAX.setFrame(window, cocoaRect: target)
                if let zone = pendingZone, let visible = pendingVisible {
                    offerAssist(afterSnapTo: zone, in: visible, window: window)
                }
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
        pendingZone = nil
        pendingVisible = nil
    }

    // MARK: - Keyboard snapping

    private func perform(_ action: SnapHotkeys.Action) {
        assist.dismiss()     // a fresh snap action supersedes any open picker
        guard isRunning,
              let window = WindowAX.focusedWindow(),
              let axFrame = WindowAX.frame(of: window) else { return }
        let current = ScreenGeometry.cocoaRect(fromAX: axFrame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) ?? NSScreen.main
        else { return }

        var zone: Zone
        var targetScreen = screen
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

        // Already snapped to that half? Continue onto the adjacent display,
        // entering from its near edge (Win+arrow walks across monitors).
        if zone == .left || zone == .right,
           approxEqual(current, zone.rect(in: screen.visibleFrame)),
           let adjacent = adjacentScreen(toThe: zone, of: screen) {
            targetScreen = adjacent
            zone = (zone == .left) ? .right : .left
        }

        let target = zone.rect(in: targetScreen.visibleFrame)
        noteSnap(of: window, from: current, to: target)
        WindowAX.setFrame(window, cocoaRect: target)
        offerAssist(afterSnapTo: zone, in: targetScreen.visibleFrame, window: window)
    }

    /// The nearest screen in `zone`'s direction (.left/.right only), or nil at the
    /// edge of the arrangement.
    private func adjacentScreen(toThe zone: Zone, of screen: NSScreen) -> NSScreen? {
        let others = NSScreen.screens.filter { $0 != screen }
        switch zone {
        case .left:  return others.filter { $0.frame.midX < screen.frame.midX }
                                  .max { $0.frame.midX < $1.frame.midX }
        case .right: return others.filter { $0.frame.midX > screen.frame.midX }
                                  .min { $0.frame.midX < $1.frame.midX }
        default:     return nil
        }
    }

    // MARK: - Snap Assist chaining

    /// A snap leaves empty zones to fill: a half leaves the other half, a quarter
    /// leaves its sibling quarter and then the opposite half. Start a session that
    /// offers them in that order, excluding the window just placed.
    private func offerAssist(afterSnapTo zone: Zone, in visible: CGRect, window: AXUIElement) {
        let queue: [CGRect]
        switch zone {
        case .left:        queue = [Zone.right.rect(in: visible)]
        case .right:       queue = [Zone.left.rect(in: visible)]
        case .topLeft:     queue = [Zone.bottomLeft.rect(in: visible), Zone.right.rect(in: visible)]
        case .bottomLeft:  queue = [Zone.topLeft.rect(in: visible), Zone.right.rect(in: visible)]
        case .topRight:    queue = [Zone.bottomRight.rect(in: visible), Zone.left.rect(in: visible)]
        case .bottomRight: queue = [Zone.topRight.rect(in: visible), Zone.left.rect(in: visible)]
        case .maximize:    return
        }
        assistSession = AssistSession(pendingZones: queue, exclusions: [exclusion(for: window)])
        assist.show(zone: queue[0], excluding: assistSession!.exclusions)
    }

    /// A pick landed — exclude the placed window and offer the next empty zone,
    /// if the session has one.
    private func advanceAssist(afterPlacing window: AXUIElement) {
        guard var session = assistSession, !session.pendingZones.isEmpty else { return }
        session.pendingZones.removeFirst()
        session.exclusions.append(exclusion(for: window))
        assistSession = session
        guard let next = session.pendingZones.first else { return }
        assist.show(zone: next, excluding: session.exclusions)
    }

    private func exclusion(for window: AXUIElement) -> (pid: pid_t, title: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return (pid, WindowAX.title(of: window) ?? "")
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
