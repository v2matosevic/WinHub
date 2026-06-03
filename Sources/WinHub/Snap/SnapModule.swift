import AppKit
import ApplicationServices

/// Windows-style Aero Snap: drag a window to a screen edge to snap it — left edge
/// for the left half, right edge for the right half, top edge to maximize. A
/// translucent overlay previews the target while you drag; releasing applies it.
final class SnapModule: HubModule {
    let id = "window-snap"
    let title = "Snap windows to edges"
    let summary = "Drag a window to a screen edge to snap it — left/right half, top to maximize."
    let requiredPermissions: [Permission] = [.accessibility]
    let isAvailable = true
    private(set) var isRunning = false

    private enum Zone {
        case left, right, maximize
        func rect(in visible: CGRect) -> CGRect {
            switch self {
            case .left:     return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
            case .right:    return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
            case .maximize: return visible
            }
        }
    }

    private let overlay = SnapOverlay()
    private var downMonitor: Any?
    private var upMonitor: Any?
    private var pollTimer: Timer?

    private var draggedWindow: AXUIElement?
    private var initialPosition: CGPoint?
    private var isMoving = false
    private var pendingTarget: CGRect?

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        // Discrete button events come from a global monitor; the continuous drag is
        // tracked by polling the cursor (no extra permission, reliable).
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.begin() }
        upMonitor   = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp])   { [weak self] _ in self?.end() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        [downMonitor, upMonitor].forEach { if let monitor = $0 { NSEvent.removeMonitor(monitor) } }
        downMonitor = nil
        upMonitor = nil
        reset()
    }

    private func begin() {
        guard let location = CGEvent(source: nil)?.location,
              let window = WindowAX.window(atTopLeft: location) else { return }
        draggedWindow = window
        initialPosition = WindowAX.position(of: window)
        isMoving = false
        pendingTarget = nil
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.track() }
    }

    private func track() {
        guard let window = draggedWindow, let location = CGEvent(source: nil)?.location else { return }

        // Engage only once the window is actually moving — not on a plain click or an
        // in-window drag (text selection), where the window frame doesn't move.
        if !isMoving {
            guard let initial = initialPosition, let now = WindowAX.position(of: window),
                  hypot(now.x - initial.x, now.y - initial.y) > 8 else { return }
            isMoving = true
        }

        let cocoa = ScreenGeometry.cocoaPoint(fromTopLeft: location)
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
        if isMoving, let target = pendingTarget, let window = draggedWindow {
            WindowAX.setFrame(window, cocoaRect: target)
        }
        reset()
    }

    private func reset() {
        pollTimer?.invalidate()
        pollTimer = nil
        overlay.hide()
        draggedWindow = nil
        initialPosition = nil
        isMoving = false
        pendingTarget = nil
    }

    private func zone(forCursor point: CGPoint, on screen: NSScreen) -> Zone? {
        let frame = screen.frame
        let threshold: CGFloat = 6
        if point.x <= frame.minX + threshold { return .left }
        if point.x >= frame.maxX - threshold { return .right }
        if point.y >= frame.maxY - threshold { return .maximize }   // top edge (high y in Cocoa)
        return nil
    }
}
