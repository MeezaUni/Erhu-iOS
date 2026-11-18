import AudioToolbox
import AVFoundation
import Foundation
import os

/// The user's equaliser on the audio thread (Android's CustomEqAudioProcessor): up to 8 bands per
/// channel, each one to four cookbook biquads ([BandFilter]). Settings come from the main thread
/// through a lock the audio thread only ever *tries*; if it is busy, the previous settings play
/// one more buffer. A change cross-fades in over 20 ms (no click while a band is dragged), and a
/// safety limiter after the bands keeps boosts from clipping.
final class EqKernel: RenderKernel, @unchecked Sendable {
    struct Parameters: Equatable {
        var enabled = true
        var bands: [BandSpec] = SoundSettings().effectiveBands()

        init() {}

        init(_ settings: SoundSettings) {
            enabled = settings.isEqEnabled
            bands = settings.effectiveBands().map(EqKernel.sanitized)
        }
    }

    /// Long enough to hide a coefficient change, short enough to feel immediate while dragging.
    private static let fadeSeconds: Float = 0.02
    private static let limit: Float = 0.97
    private static let limiterReleaseSeconds: Float = 0.15
    private static let limiterSnap: Float = 0.0005

    private let pending = OSAllocatedUnfairLock<Parameters?>(initialState: nil)
    private let published = OSAllocatedUnfairLock(initialState: RuntimeState())

    // Audio thread only. Both banks are allocated in prepare(), never while audio plays.
    private var parameters = Parameters()
    private var current: [[BandFilter]] = []
    private var next: [[BandFilter]] = []
    private var currentFlat = true
    private var fading = false
    private var fadePosition = 0
    private var fadeLength = 1
    private var limiterGain: Float = 1
    private var limiterRelease: Float = 0
    private var frame: [Float] = []
    private var channelData: [UnsafeMutablePointer<Float>?] = []
    private var sampleRate = 44_100
    private var channels = 0
    private var needsConfigure = true

    struct RuntimeState: Equatable {
        var configured = false
        var sampleRateHz: Int?
        var channelCount: Int?
    }

    func apply(_ settings: SoundSettings) {
        pending.withLock { $0 = Parameters(settings) }
    }

    static func sanitized(_ spec: BandSpec) -> BandSpec {
        var s = spec
        s.frequencyHz = s.frequencyHz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)
        s.gainDb = s.type.hasGain ? s.gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb) : 0
        s.q = s.q.clamped(Equalizer.minQ, Equalizer.maxQ)
        if !BandFilter.slopes.contains(s.slope) { s.slope = 12 }
        return s
    }

    /// What the stage is doing now, for the audio inspector.
    func runtimeState(settings: SoundSettings) -> EqRuntimeState {
        let state = published.withLock { $0 }
        return EqRuntimeState(
            enabled: settings.isEqEnabled,
            configured: state.configured,
            sampleRateHz: state.sampleRateHz,
            channelCount: state.channelCount,
            allGainsZero: Self.isFlat(settings.effectiveBands())
        )
    }

    /// No band changes the sound (all off, or 0 dB peaks and shelves).
    static func isFlat(_ bands: [BandSpec]) -> Bool {
        bands.allSatisfy { !$0.enabled || ($0.type.hasGain && $0.gainDb == 0) }
    }

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = Int(sampleRate)
        self.channels = channels
        let bank = Array(repeating: Array(repeating: BandFilter(), count: Equalizer.bandCount), count: channels)
        current = bank
        next = bank
        frame = Array(repeating: 0, count: channels)
        channelData = Array(repeating: nil, count: channels)
        currentFlat = true
        fading = false
        limiterGain = 1
        limiterRelease = 1 - exp(-1 / (Float(max(self.sampleRate, 1)) * Self.limiterReleaseSeconds))
        needsConfigure = true
        published.withLock { $0 = RuntimeState(configured: true, sampleRateHz: Int(sampleRate), channelCount: channels) }
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        if let latest = pending.withLockIfAvailable({ value -> Parameters? in
            defer { value = nil }
            return value
        }) ?? nil {
            if latest.enabled != parameters.enabled { resetFilters() }
            if latest != parameters { needsConfigure = true }
            parameters = latest
        }
        guard parameters.enabled, current.count == buffers.count, buffers.count == channels, channels > 0 else { return }
        if needsConfigure { configure() }
        guard !currentFlat || fading || limiterGain < 1 else { return }
        for channel in 0..<channels {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { return }
            channelData[channel] = data
        }
        for i in 0..<frames {
            let t = fading ? Float(fadePosition) / Float(fadeLength) : 1
            var loudest: Float = 0
            for channel in 0..<channels {
                let x = channelData[channel]![i]
                var y = x
                for b in 0..<Equalizer.bandCount { y = current[channel][b].process(y) }
                if fading {
                    var z = x
                    for b in 0..<Equalizer.bandCount { z = next[channel][b].process(z) }
                    y += (z - y) * t
                }
                frame[channel] = y
                loudest = max(loudest, abs(y))
            }
            // Boosts keep their full effect; only a sample that would clip pulls the level down
            // (at once), which then recovers smoothly.
            let allowed = loudest > Self.limit ? Self.limit / loudest : 1
            limiterGain = allowed < limiterGain ? allowed : min(1, limiterGain + (1 - limiterGain) * limiterRelease)
            if limiterGain > 1 - Self.limiterSnap { limiterGain = 1 }
            for channel in 0..<channels {
                let y = limiterGain < 1 ? frame[channel] * limiterGain : frame[channel]
                channelData[channel]![i] = y.isFinite ? y.clamped(-1, 1) : 0
            }
            if fading {
                fadePosition += 1
                if fadePosition >= fadeLength { finishFade() }
            }
        }
    }

    /// Builds the latest settings into the spare bank and fades it in (at once when nothing
    /// changes the sound before or after).
    private func configure() {
        needsConfigure = false
        if fading { finishFade() }
        for channel in 0..<channels {
            for b in 0..<Equalizer.bandCount {
                let spec = b < parameters.bands.count ? parameters.bands[b] : BandSpec(type: .peaking, frequencyHz: 1000, gainDb: 0, q: Equalizer.defaultQ)
                next[channel][b].configure(spec, sampleRate: sampleRate)
                next[channel][b].copyState(from: current[channel][b])
            }
        }
        let nowFlat = Self.isFlat(parameters.bands)
        if currentFlat && nowFlat {
            swap(&current, &next)
            currentFlat = true
            return
        }
        fading = true
        fadePosition = 0
        fadeLength = max(Int(Float(sampleRate) * Self.fadeSeconds), 1)
    }

    private func finishFade() {
        swap(&current, &next)
        fading = false
        currentFlat = current.first?.allSatisfy(\.isIdentity) ?? true
    }

    private func resetFilters() {
        for channel in current.indices {
            for b in current[channel].indices {
                current[channel][b].reset()
                next[channel][b].reset()
            }
        }
        fading = false
        limiterGain = 1
    }

    /// The combined response in dB at each of [frequencies] (for drawing the EQ curve).
    static func response(of settings: SoundSettings, at frequencies: [Float], sampleRate: Int = 44_100) -> [Float] {
        BandFilter.response(of: settings.effectiveBands().map(sanitized), at: frequencies, sampleRate: sampleRate)
    }
}
