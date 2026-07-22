import AppKit
import ApplicationServices

/// Windows Snap Assist: after a window is snapped to a half, offer the other open
/// windows as thumbnails in the empty half; picking one snaps it there. Owns the
/// capture and the picker panel; the actual window move is delegated back to
/// SnapModule via `onPick`, which keeps the snap registry in one place.
final class SnapAssist {
    /// Snap `window` to `target` (a Cocoa rect) — implemented by SnapModule so the
    /// pick is recorded like any other snap (⌃⌥↓ restore keeps working).
    var onPick: ((AXUIElement, CGRect) -> Void)?

    private let panel = SnapAssistPanel()
    private let thumbnails = WindowThumbnailService()
    private var clickMonitor: Any?
    private var targetZone: CGRect = .zero
    private var generation = 0

    init() {
        panel.onPick = { [weak self] shot in self?.pick(shot) }
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    /// Offer candidates for the empty `zone` (Cocoa rect). Already-placed windows
    /// are excluded by owner + title. No-op without Screen Recording permission —
    /// the first attempt raises the system prompt so granting is one click away.
    func show(zone: CGRect, excluding: [(pid: pid_t, title: String)]) {
        guard Permission.screenRecording.isGranted else {
            Permissions.requestScreenRecording()
            return
        }
        targetZone = zone
        generation += 1
        let token = generation

        Task { @MainActor in
            var shots = await self.thumbnails.captureSnapCandidates(excluding: excluding)
            // Minimized windows get reserved slots — on a busy desktop the
            // on-screen windows would otherwise always crowd them out.
            let minimized = self.minimizedCandidates(excluding: excluding, limit: 3)
            shots = Array(shots.prefix(9 - minimized.count)) + minimized
            guard token == self.generation, !shots.isEmpty else { return }
            self.panel.show(shots, zone: zone)
            self.installClickMonitor()
        }
    }

    func dismiss() {
        generation += 1
        panel.dismiss()
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }

    // MARK: - Internals

    /// A click in any other app means the user moved on — global monitors don't
    /// fire for our own windows, so clicks on the panel itself are unaffected.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
    }

    /// Minimized windows can't be captured — offer them as app-icon placeholders,
    /// like Dock previews do (Windows lists them in Snap Assist too). Untitled ones
    /// are skipped: with no title and no on-screen frame there is nothing to match
    /// the pick back to.
    private func minimizedCandidates(excluding: [(pid: pid_t, title: String)],
                                     limit: Int) -> [WindowShot] {
        guard limit > 0 else { return [] }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var shots: [WindowShot] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            for window in WindowAX.windows(ofAppWithPID: app.processIdentifier)
            where WindowAX.isMinimized(window) {
                guard let title = WindowAX.title(of: window), !title.isEmpty,
                      !excluding.contains(where: { $0.pid == app.processIdentifier && $0.title == title }),
                      let icon = app.icon?.cgImageRep() else { continue }
                shots.append(WindowShot(windowID: 0, ownerPID: app.processIdentifier,
                                        title: title, frame: .zero, image: icon))
                if shots.count == limit { return shots }
            }
        }
        return shots
    }

    private func pick(_ shot: WindowShot) {
        let zone = targetZone
        dismiss()
        guard let window = axWindow(for: shot) else { return }
        // Un-minimize first (no-op if it wasn't) so the frame set actually lands.
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        onPick?(window, zone)

        // Bring the chosen window forward — it may have been buried or on another
        // display, and Windows focuses the newly placed window too.
        NSRunningApplication(processIdentifier: shot.ownerPID)?.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let axApp = AXUIElementCreateApplication(shot.ownerPID)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
    }

    /// Match a captured shot back to its AX window: by title when there is one,
    /// else by on-screen frame (both AX-space). A miss means the window closed or
    /// changed since capture — do nothing rather than snap the wrong window.
    private func axWindow(for shot: WindowShot) -> AXUIElement? {
        let windows = WindowAX.windows(ofAppWithPID: shot.ownerPID)
        if !shot.title.isEmpty,
           let match = windows.first(where: { WindowAX.title(of: $0) == shot.title }) {
            return match
        }
        return windows.first { window in
            guard let frame = WindowAX.frame(of: window) else { return false }
            return abs(frame.minX - shot.frame.minX) < 8 && abs(frame.minY - shot.frame.minY) < 8 &&
                   abs(frame.width - shot.frame.width) < 8 && abs(frame.height - shot.frame.height) < 8
        }
    }
}
