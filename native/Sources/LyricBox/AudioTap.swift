import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

/* Real beat detection from Spotify's own audio.

   A Core Audio process tap (macOS 14.2+) listens to Spotify's processes only, through a
   private aggregate device. It needs the "audio from other apps" permission
   (NSAudioCaptureUsageDescription); nothing is recorded or stored, the samples are only
   reduced to a bass-energy envelope to find beats. Beats are delivered on the main queue,
   delayed by the output device's latency so they land when you actually hear them. */

/// Bass-onset beat detector with a running tempo estimate. Runs on the audio thread.
final class BeatDetector {
    private let fs: Double
    private let a: Double            // one-pole low-pass coefficient (~150 Hz)
    private var lp1 = 0.0, lp2 = 0.0
    private var acc = 0.0, accN = 0
    private var accFull = 0.0, prevFull = 0.0
    private let window: Int          // ~11 ms of samples per energy value
    private var avg = 0.0            // slow average of bass energy
    private var prev = 0.0
    private var level = 0.0          // overall loudness (for silence detection)
    private var t = 0.0              // seconds of audio seen
    private var lastBeat = -1.0
    private(set) var bpm = 0.0
    private(set) var stable = false

    // tempo: autocorrelation of the onset envelope over the last ~6 s
    private var env: [Double]
    private var envIdx = 0, envCount = 0, sinceTempo = 0
    private var estimates: [Double] = []
    private var frameDur: Double { Double(window) / fs }

    init(sampleRate: Double) {
        fs = sampleRate
        a = exp(-2 * Double.pi * 150 / sampleRate)
        window = max(64, Int(sampleRate * 0.011))
        env = Array(repeating: 0, count: Int(6 / (Double(window) / sampleRate)))
    }

    private func updateTempo() {
        let n = env.count
        guard envCount >= n / 2 else { return }
        let lagMin = Int(60 / 180 / frameDur), lagMax = Int(60 / 70 / frameDur)
        var best = 0.0, bestLag = 0
        for lag in lagMin...lagMax {
            var sum = 0.0
            for i in lag..<min(envCount, n) {
                sum += env[(envIdx - i + n) % n] * env[(envIdx - i + lag + n) % n]
            }
            // prefer tempos around 120 BPM (log-normal prior), like most tempo trackers
            let b = 60 / (Double(lag) * frameDur)
            let w = exp(-0.5 * pow(log2(b / 120) / 0.9, 2))
            if sum * w > best { best = sum * w; bestLag = lag }
        }
        guard bestLag > 0, best > 0 else { return }
        estimates.append(60 / (Double(bestLag) * frameDur))
        if estimates.count > 5 { estimates.removeFirst() }
        let sorted = estimates.sorted()
        // only report a tempo once the recent estimates agree (±4%)
        let median = sorted[sorted.count / 2]
        stable = sorted.count >= 4 && sorted.allSatisfy { abs($0 / median - 1) < 0.04 }
        bpm = median
    }

    /// Feed mono samples; returns beat strengths (0…1) found in this chunk.
    func process(_ x: UnsafePointer<Float>, count: Int, stride: Int, onBeat: (Double) -> Void) {
        var i = 0
        while i < count * stride {
            let s = Double(x[i])
            lp1 = (1 - a) * s + a * lp1
            lp2 = (1 - a) * lp1 + a * lp2
            acc += lp2 * lp2
            accFull += s * s
            level = level * 0.9995 + abs(s) * 0.0005
            accN += 1
            if accN == window {
                let e = acc / Double(window), full = accFull / Double(window)
                acc = 0
                accFull = 0
                accN = 0
                t += Double(window) / fs
                // onset envelope for the tempo: rise in bass + full-band log energy
                let flux = max(0, log(e + 1e-9) - log(prev + 1e-9)) + max(0, log(full + 1e-9) - log(prevFull + 1e-9))
                prevFull = full
                step(e, flux, onBeat)
            }
            i += stride
        }
    }

    private func step(_ e: Double, _ flux: Double, _ onBeat: (Double) -> Void) {
        defer {
            avg = avg == 0 ? e : avg * 0.985 + e * 0.015    // ~0.7 s memory
            prev = e
        }
        env[envIdx] = flux
        envIdx = (envIdx + 1) % env.count
        envCount = min(envCount + 1, env.count)
        sinceTempo += 1
        if sinceTempo * window >= Int(fs) {           // once a second
            sinceTempo = 0
            updateTempo()
        }

        guard level > 0.002, avg > 0 else { return }       // silence
        let ratio = e / avg
        // a beat: bass jumps well above its recent average, at most ~200 BPM
        guard ratio > 1.45, e > prev, t - lastBeat > 0.3 else { return }
        lastBeat = t
        onBeat(min(1, (ratio - 1.45) / 1.6 + 0.35))
    }
}

@available(macOS 14.2, *)
final class SpotifyAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "lyricbox.audio", qos: .userInteractive)
    private var detector: BeatDetector?
    private(set) var running = false
    private(set) var lastAudio = Date.distantPast   // last time a non-silent buffer arrived
    private var latency = 0.0

    var onBeat: ((Double) -> Void)?
    /// Tempo, or 0 while it isn't stable yet.
    var bpm: Double { detector?.stable == true ? detector!.bpm : 0 }

    deinit { stop() }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> T? {
        var addr = address(selector, scope)
        var v = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var s: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return err == noErr ? s as String : nil
    }

    /// Core Audio process objects belonging to Spotify (main app and helpers).
    private static func spotifyProcesses() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (readString($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(SpotifyMonitor.bundleID) }
    }

    /// Seconds between audio leaving the app and reaching your ears (device + safety offset + buffer).
    private static func outputLatency() -> Double {
        guard let dev = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)),
              let rate = read(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)), rate > 0 else { return 0.03 }
        let out = kAudioObjectPropertyScopeOutput
        let frames = Double(read(dev, kAudioDevicePropertyLatency, out, UInt32(0)) ?? 0)
            + Double(read(dev, kAudioDevicePropertySafetyOffset, out, UInt32(0)) ?? 0)
            + Double(read(dev, kAudioDevicePropertyBufferFrameSize, out, UInt32(0)) ?? 0)
        return min(0.5, frames / rate)
    }

    private static func defaultOutputUID() -> String? {
        guard let dev = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) else { return nil }
        return readString(dev, kAudioDevicePropertyDeviceUID)
    }

    // MARK: start / stop

    /// Starts tapping Spotify. Returns false if Spotify has no audio process yet or Core Audio refused.
    @discardableResult
    func start() -> Bool {
        stop()
        let procs = Self.spotifyProcesses()
        guard !procs.isEmpty, let outUID = Self.defaultOutputUID() else { return false }

        let desc = CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return false }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyric Box Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID) == noErr else { stop(); return false }

        let fmt = Self.read(tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
        let rate = fmt?.mSampleRate ?? 48000
        let interleaved = (fmt?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(fmt?.mChannelsPerFrame ?? 2)
        let det = BeatDetector(sampleRate: rate)
        detector = det
        latency = Self.outputLatency()

        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buf = list.first, let data = buf.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / (interleaved ? max(1, channels) : 1)
            if frames > 0, abs(samples[0]) + abs(samples[frames / 2]) > 0 { self.lastAudio = Date() }
            // left channel is enough for bass beats
            det.process(samples, count: frames, stride: interleaved ? max(1, channels) : 1) { strength in
                let delay = self.latency
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.onBeat?(strength) }
            }
        }
        guard err == noErr, let procID else { stop(); return false }
        guard AudioDeviceStart(aggregateID, procID) == noErr else { stop(); return false }
        running = true
        lastAudio = Date()
        return true
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }
}
