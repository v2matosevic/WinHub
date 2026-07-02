import AppKit
import Combine
import ImageIO

/// A snapshot of what's playing system-wide.
struct NowPlaying {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    /// When `elapsed` was sampled — the playhead is extrapolated from here.
    var timestamp: Date?
    var playbackRate: Double = 1
    var playing = false
    var bundleID: String?

    /// Best estimate of the current playhead without polling.
    func estimatedElapsed(at date: Date = Date()) -> Double? {
        guard let elapsed else { return nil }
        guard playing, let timestamp else { return elapsed }
        let rate = playbackRate == 0 ? 1 : playbackRate
        let value = elapsed + date.timeIntervalSince(timestamp) * rate
        if let duration { return min(value, duration) }
        return value
    }
}

/// System-wide now-playing state + transport commands via the vendored
/// MediaRemoteAdapter (BSD-3, github.com/ungive/mediaremote-adapter — see
/// THIRD_PARTY_LICENSES). Apple restricted third-party MediaRemote access in
/// macOS 15.4; the adapter runs under /usr/bin/perl, which still carries the
/// entitlement, and streams NDJSON diffs of the now-playing state to stdout.
@MainActor
final class MediaWatcher: ObservableObject {
    @Published private(set) var now = NowPlaying()
    @Published private(set) var artwork: NSImage?
    /// Vibrant accent pulled from the artwork — tints the scrubber, equalizer
    /// and ambient glow. Nil falls back to white.
    @Published private(set) var accent: NSColor?
    /// Icon of the app the audio comes from (badge on the artwork).
    @Published private(set) var sourceAppIcon: NSImage?
    /// False when the adapter is missing or non-functional on this system.
    @Published private(set) var isAvailable = true
    /// Drives the closed-notch live activity: true while playing, lingers a
    /// few seconds after a pause so quick pause/play doesn't flicker.
    @Published private(set) var hasActivity = false

    /// MediaRemote command IDs (kMRPlay etc.) understood by `send`.
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5
    }

    private var stream: Process?
    private var stdoutBuffer = Data()
    /// Accumulated now-playing dictionary; stream messages are diffs onto this.
    private var raw: [String: Any] = [:]
    /// Set by parse() when a message actually touched "artworkData", so the
    /// (expensive) artwork path is skipped on plain elapsed-time diffs.
    private var artworkDirty = false
    private var lastArtworkBase64: String?
    private var idleTask: Task<Void, Never>?
    private var oneShots = Set<Process>()
    private var shouldRun = false

    // MARK: - Adapter artifacts

    // In the app bundle when launched as WinHub.app; repo fallback covers
    // bare `swift build` dev runs on this machine.
    private nonisolated static let devRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Notch/
        .deletingLastPathComponent()  // WinHub/
        .deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Resources/MediaRemoteAdapter")

    private nonisolated static var scriptURL: URL? {
        if let url = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") { return url }
        let dev = devRoot.appendingPathComponent("mediaremote-adapter.pl")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private nonisolated static var frameworkURL: URL? {
        if let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        let dev = devRoot.appendingPathComponent("MediaRemoteAdapter.framework")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private nonisolated static var testClientURL: URL? {
        if let url = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil) { return url }
        let dev = devRoot.appendingPathComponent("MediaRemoteAdapterTestClient")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Lifecycle

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else {
            NSLog("[WinHub.notch] mediaremote-adapter not bundled — media controls disabled")
            isAvailable = false
            return
        }
        probe(script: script, framework: framework)
        launchStream(script: script, framework: framework)
    }

    func stop() {
        shouldRun = false
        idleTask?.cancel()
        stopStream()
        raw = [:]
        now = NowPlaying()
        artwork = nil
        accent = nil
        lastArtworkBase64 = nil
        hasActivity = false
    }

    /// Verify the adapter is entitled to talk to MediaRemote on this system.
    private func probe(script: URL, framework: URL) {
        guard let client = Self.testClientURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path, client.path, "test"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                self.isAvailable = ok
                if !ok {
                    NSLog("[WinHub.notch] MediaRemote adapter probe failed (status %d) — media UI disabled",
                          proc.terminationStatus)
                    self.stopStream()
                }
            }
        }
        do { try p.run() } catch {
            NSLog("[WinHub.notch] adapter probe failed to launch: \(error)")
        }
    }

    private func launchStream(script: URL, framework: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path, "stream", "--debounce=100"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.isAvailable else { return }
                // Stream died under us — relaunch after a beat.
                NSLog("[WinHub.notch] adapter stream exited; relaunching in 2 s")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.shouldRun, self.isAvailable, self.stream?.isRunning != true else { return }
                self.launchStream(script: script, framework: framework)
            }
        }
        do {
            try p.run()
            stream = p
        } catch {
            NSLog("[WinHub.notch] failed to launch adapter stream: \(error)")
            isAvailable = false
        }
    }

    private func stopStream() {
        guard let stream else { return }
        stream.terminationHandler = nil
        (stream.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if stream.isRunning { stream.terminate() }
        self.stream = nil
        stdoutBuffer = Data()
    }

    // MARK: - Stream parsing

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty else { continue }
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["payload"] is NSNull {
            raw = [:]
            artworkDirty = true
        } else if let payload = object["payload"] as? [String: Any] {
            if object["diff"] as? Bool == true {
                if payload.keys.contains("artworkData") { artworkDirty = true }
                for (key, value) in payload {
                    if value is NSNull {
                        raw.removeValue(forKey: key)
                    } else {
                        raw[key] = value
                    }
                }
            } else {
                raw = payload
                artworkDirty = true
            }
        } else {
            return
        }
        apply()
    }

    private func apply() {
        var info = NowPlaying()
        info.title = raw["title"] as? String
        info.artist = raw["artist"] as? String
        info.album = raw["album"] as? String
        info.duration = doubleValue(raw["duration"])
        info.elapsed = doubleValue(raw["elapsedTime"])
        info.playbackRate = doubleValue(raw["playbackRate"]) ?? 1
        info.playing = raw["playing"] as? Bool ?? false
        info.bundleID = (raw["parentApplicationBundleIdentifier"] as? String)
            ?? (raw["bundleIdentifier"] as? String)
        info.timestamp = parseTimestamp(raw["timestamp"])
        let bundleChanged = info.bundleID != now.bundleID
        now = info
        if bundleChanged { updateSourceAppIcon() }
        if artworkDirty {
            artworkDirty = false
            updateArtwork()
        }
        updateActivity()
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private func parseTimestamp(_ any: Any?) -> Date? {
        if let s = any as? String {
            return Self.isoFractional.date(from: s) ?? Self.iso.date(from: s)
        }
        if let epoch = doubleValue(any) { return Date(timeIntervalSince1970: epoch) }
        return nil
    }

    private func updateArtwork() {
        guard let base64 = raw["artworkData"] as? String else {
            // The stream removed the artwork (track change, source gone) —
            // don't let the previous track's cover linger.
            artwork = nil
            accent = nil
            lastArtworkBase64 = nil
            return
        }
        guard base64 != lastArtworkBase64 else { return }
        lastArtworkBase64 = base64
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeArtwork(base64)
            let accent = image.flatMap { ArtworkPalette.accent(from: $0) }
            Task { @MainActor in
                self?.artwork = image
                self?.accent = accent
            }
        }
    }

    /// Decode + downsample off the main thread. The UI never shows the cover
    /// larger than ~100 pt (and blurs it for the glow), so full-resolution art
    /// only wastes memory and makes the blur pass expensive.
    private nonisolated static func decodeArtwork(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func updateSourceAppIcon() {
        guard let bundleID = now.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            sourceAppIcon = nil
            return
        }
        sourceAppIcon = NSWorkspace.shared.icon(forFile: url.path)
    }

    private func updateActivity() {
        if now.playing {
            idleTask?.cancel()
            idleTask = nil
            hasActivity = true
        } else if now.title == nil {
            idleTask?.cancel()
            idleTask = nil
            hasActivity = false
        } else if hasActivity, idleTask == nil {
            // Paused: keep the live activity up briefly, then let it collapse.
            // The timer must survive unrelated diffs (elapsed updates etc.),
            // so it's only created once per pause.
            idleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.idleTask = nil
                self?.hasActivity = false
            }
        }
    }

    // MARK: - Commands

    func send(_ command: Command) {
        runOneShot(["send", String(command.rawValue)])
        // Optimistic flip so the button feels instant; the stream corrects us.
        // Mirror into `raw` too — apply() rebuilds from it on every diff, and
        // diffs that don't mention "playing" must not revert the flip.
        if command == .togglePlayPause {
            now.playing.toggle()
            now.timestamp = Date()
            raw["playing"] = now.playing
            if now.playing { hasActivity = true }
        }
    }

    func seek(to seconds: Double) {
        runOneShot(["seek", String(Int(seconds * 1_000_000))])
        now.elapsed = seconds
        now.timestamp = Date()
    }

    private func runOneShot(_ args: [String]) {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.oneShots.remove(proc) }
        }
        do {
            try p.run()
            oneShots.insert(p)  // retain until exit
        } catch {
            NSLog("[WinHub.notch] media command failed to launch: \(error)")
        }
    }
}
