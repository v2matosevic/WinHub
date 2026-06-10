import AppKit
import Accelerate
import CoreAudio

/// Four smoothed frequency-band levels (0…1, bass → treble) of whatever the
/// system is playing, captured through a Core Audio process tap (macOS 14.2+,
/// one-time "record system audio" permission). If the tap can't start —
/// older OS, permission declined — `isRunning` stays false and the
/// visualizer keeps its choreographed fallback.
@MainActor
final class SystemAudioLevels {
    private(set) var isRunning = false
    /// Latched after a failed start so we don't re-prompt/log on every track
    /// tick. Cleared when the module restarts.
    private var failed = false
    private var engine: AudioTapEngine?

    /// Latest band levels — read per frame by the visualizer.
    var current: [Float] {
        engine?.snapshot() ?? [0, 0, 0, 0]
    }

    private var requesting = false

    /// Begin tapping the system audio mix (a global tap, so it follows whatever
    /// is audible without caring which app or helper process is the source).
    func start() {
        guard !isRunning, !failed, !requesting else { return }
        guard #available(macOS 14.2, *) else {
            failed = true
            NSLog("[WinHub.notch] audio tap needs macOS 14.2+ — visualizer stays choreographed")
            return
        }

        // Core Audio taps don't prompt on their own — without the audio-capture
        // TCC grant they "work" but deliver silence. Ask explicitly first.
        requesting = true
        AudioCapturePermission.request { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.requesting = false
                guard granted else {
                    self.failed = true
                    NSLog("[WinHub.notch] system-audio permission declined — visualizer stays choreographed")
                    return
                }
                guard !self.isRunning else { return }
                let engine = AudioTapEngine()
                do {
                    try engine.start()
                    self.engine = engine
                    self.isRunning = true
                    NSLog("[WinHub.notch] system audio tap running")
                } catch {
                    self.failed = true
                    NSLog("[WinHub.notch] audio tap unavailable (\(error)) — visualizer stays choreographed")
                }
            }
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
    }
}

private struct AudioTapError: Error, CustomStringConvertible {
    let stage: String
    let status: OSStatus
    var description: String { "\(stage): OSStatus \(status)" }
}

/// The system-audio-capture TCC grant. There is no public request API for it
/// (Core Audio taps silently deliver zeros when unauthorized), so this asks
/// TCC.framework directly — the established pattern for tap-based capture
/// apps. The prompt shows `NSAudioCaptureUsageDescription` from Info.plist.
private enum AudioCapturePermission {
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessRequest") else {
            NSLog("[WinHub.notch] TCC request unavailable — assuming no audio-capture grant")
            completion(false)
            return
        }
        typealias TCCAccessRequestFn = @convention(c) (
            CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        let request = unsafeBitCast(symbol, to: TCCAccessRequestFn.self)
        request("kTCCServiceAudioCapture" as CFString, nil) { granted in
            completion(granted)
        }
    }
}

/// Core Audio plumbing + DSP. After `start()`, all DSP state is touched only
/// on the serial IO queue; the UI thread only ever takes `snapshot()`.
private final class AudioTapEngine: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "hr.version2.winhub.notch-audiotap")

    // Shared with the audio thread.
    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: 4)

    // DSP state (IO queue only). Preallocated — the audio path must not allocate.
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private var fftSetup: FFTSetup?
    private var hann = [Float]()
    private var pending = [Float]()
    private var windowed = [Float]()
    private var splitReal = [Float]()
    private var splitImag = [Float]()
    private var magnitudes = [Float]()
    private var bandBins: [ClosedRange<Int>] = []
    private var peaks = [Float](repeating: 1e-4, count: 4)
    private var channels = 2

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw AudioTapError(stage: "availability", status: -1)
        }

        // 1. A global stereo-mixdown tap of the whole system. Targeting a
        //    single app's PID misses Chromium-based players (Spotify, browsers)
        //    that render audio from a separate helper subprocess; the global
        //    mix catches every source that's actually audible.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "WinHub Notch Visualizer"
        tapDescription.isPrivate = false
        tapDescription.muteBehavior = .unmuted
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check("create tap", AudioHardwareCreateProcessTap(tapDescription, &newTap))
        tapID = newTap

        // 2. The tap's stream format drives the DSP setup.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd))
        channels = max(1, Int(asbd.mChannelsPerFrame))
        prepareDSP(sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000)

        // 3. Private aggregate device wrapping the default output + the tap.
        //    A fresh UID every run — a fixed one collides with aggregates
        //    leaked by a process that didn't tear down cleanly, and the
        //    re-created device then never runs its IO.
        let outputUID = try defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WinHub Notch Tap",
            kAudioAggregateDeviceUIDKey: "hr.version2.winhub.notch-tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try check("create aggregate", AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate))
        aggregateID = newAggregate

        // 4. Pull buffers.
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            self?.ingest(inputData)
        }
        try check("create io proc", status)
        procID = newProc
        try check("start device", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.2, *), tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        fftSetup = nil
    }

    deinit {
        stop()
    }

    // MARK: - DSP

    private func prepareDSP(sampleRate: Double) {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        splitReal = [Float](repeating: 0, count: fftSize / 2)
        splitImag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        pending = []
        pending.reserveCapacity(fftSize * 8)

        // Log-spaced bands: bass, low-mids, high-mids, treble.
        let hzPerBin = sampleRate / Double(fftSize)
        let edges: [Double] = [40, 180, 700, 2800, min(12000, sampleRate / 2 - hzPerBin)]
        bandBins = (0..<4).map { band in
            let lo = min(fftSize / 2 - 2, max(1, Int(edges[band] / hzPerBin)))
            let hi = min(fftSize / 2 - 1, max(lo, Int(edges[band + 1] / hzPerBin)))
            return lo...hi
        }
        peaks = [Float](repeating: 1e-4, count: 4)
    }

    private func ingest(_ list: UnsafePointer<AudioBufferList>) {
        // The aggregate can expose several input streams and the tap isn't
        // guaranteed to be buffer 0 — feed the DSP from the loudest one.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var bestSamples: UnsafeMutablePointer<Float>?
        var bestCount = 0
        var bestChannels = 1
        var bestMagnitude: Float = -1
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            var magnitude: Float = 0
            vDSP_maxmgv(samples, 1, &magnitude, vDSP_Length(count))
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestSamples = samples
                bestCount = count
                bestChannels = max(1, Int(buffer.mNumberChannels))
            }
        }
        guard let samples = bestSamples, bestCount > 0 else { return }

        if bestChannels > 1 {
            let frames = bestCount / bestChannels
            for frame in 0..<frames {
                var acc: Float = 0
                for ch in 0..<bestChannels { acc += samples[frame * bestChannels + ch] }
                pending.append(acc / Float(bestChannels))
            }
        } else {
            pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: bestCount))
        }

        while pending.count >= fftSize {
            processChunk()
            pending.removeFirst(fftSize / 2)  // 50% hop — smoother level updates
        }
    }

    private func processChunk() {
        pending.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))
        }
        windowed.withUnsafeBufferPointer { input in
            splitReal.withUnsafeMutableBufferPointer { re in
                splitImag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup!, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }
        }
        magnitudes[0] = 0  // DC (and the packed Nyquist) out of the bands

        var fresh = [Float](repeating: 0, count: 4)
        for (band, bins) in bandBins.enumerated() {
            var energy: Float = 0
            for bin in bins { energy += magnitudes[bin] }
            let amplitude = sqrt(energy / Float(bins.count))
            // Slow-decaying running peak as a per-band auto-gain, so quiet
            // and loud tracks both use the full bar range.
            peaks[band] = max(amplitude, peaks[band] * 0.9985)
            fresh[band] = min(1, amplitude / max(peaks[band] * 0.85, 1e-6))
        }

        lock.lock()
        for band in 0..<4 {
            let previous = levels[band]
            let target = fresh[band]
            levels[band] = target > previous
                ? previous + (target - previous) * 0.55  // fast attack
                : previous + (target - previous) * 0.18  // slower release
        }
        lock.unlock()
    }

    // MARK: - Helpers

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check("default output", AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID))

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check("output uid", withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        })
        return uid as String
    }

    private func check(_ stage: String, _ status: OSStatus) throws {
        guard status == noErr else { throw AudioTapError(stage: stage, status: status) }
    }
}
