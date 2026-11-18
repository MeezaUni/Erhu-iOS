import Foundation

/// Saved by name; new types are only ever appended.
enum FilterType: String, CaseIterable, Codable {
    case peaking = "PEAKING"
    case lowShelf = "LOW_SHELF"
    case highShelf = "HIGH_SHELF"
    case lowPass = "LOW_PASS"
    case highPass = "HIGH_PASS"
    case notch = "NOTCH"

    /// Peak and shelves change the level by a gain; pass filters and the notch have none.
    var hasGain: Bool { self == .peaking || self == .lowShelf || self == .highShelf }
    var isPass: Bool { self == .lowPass || self == .highPass }

    var label: String {
        switch self {
        case .peaking: String(localized: "Peak")
        case .lowShelf: String(localized: "Low shelf")
        case .highShelf: String(localized: "High shelf")
        case .lowPass: String(localized: "Low pass")
        case .highPass: String(localized: "High pass")
        case .notch: String(localized: "Notch")
        }
    }
}

/// Biquad IIR filter from Robert Bristow-Johnson's Audio EQ Cookbook (same maths as Android).
struct BiquadFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    private(set) var frequency: Float = 1000
    private(set) var gainDb: Float = 0
    private(set) var qFactor: Float = 1.414
    private(set) var filterType: FilterType = .peaking
    /// Passes audio unchanged (a 0 dB peak or shelf, or not configured).
    private(set) var isIdentity = true

    mutating func configure(centerFrequency: Float, sampleRate: Int, gainInDb: Float, q: Float = 1.414, type: FilterType = .peaking) {
        frequency = centerFrequency
        gainDb = gainInDb
        qFactor = q
        filterType = type
        guard sampleRate > 0, !(type.hasGain && gainInDb == 0) else {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            isIdentity = true
            return
        }
        isIdentity = false
        if !type.hasGain {
            configureCookbook(type, centerFrequency: centerFrequency, sampleRate: sampleRate, q: q)
            return
        }
        let a = pow(10.0, Double(gainInDb) / 40.0)
        let w0 = 2.0 * Double.pi * Double(centerFrequency) / Double(sampleRate)
        let cosW0 = cos(w0)
        let rawB0, rawB1, rawB2, rawA0, rawA1, rawA2: Double
        switch type {
        case .peaking, .lowPass, .highPass, .notch:
            let alpha = sin(w0) / (2.0 * Double(max(q, 0.1)))
            rawB0 = 1 + alpha * a
            rawB1 = -2 * cosW0
            rawB2 = 1 - alpha * a
            rawA0 = 1 + alpha / a
            rawA1 = -2 * cosW0
            rawA2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let inside = max((a + 1 / a) * (1 / Double(max(q, 0.1)) - 1) + 2, 0)
            let alpha = sin(w0) / 2 * sqrt(inside)
            let beta = 2 * sqrt(max(a, 0.0001)) * alpha
            if type == .lowShelf {
                rawB0 = a * ((a + 1) - (a - 1) * cosW0 + beta)
                rawB1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
                rawB2 = a * ((a + 1) - (a - 1) * cosW0 - beta)
                rawA0 = (a + 1) + (a - 1) * cosW0 + beta
                rawA1 = -2 * ((a - 1) + (a + 1) * cosW0)
                rawA2 = (a + 1) + (a - 1) * cosW0 - beta
            } else {
                rawB0 = a * ((a + 1) + (a - 1) * cosW0 + beta)
                rawB1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
                rawB2 = a * ((a + 1) + (a - 1) * cosW0 - beta)
                rawA0 = (a + 1) - (a - 1) * cosW0 + beta
                rawA1 = 2 * ((a - 1) - (a + 1) * cosW0)
                rawA2 = (a + 1) - (a - 1) * cosW0 - beta
            }
        }
        b0 = Float(rawB0 / rawA0)
        b1 = Float(rawB1 / rawA0)
        b2 = Float(rawB2 / rawA0)
        a1 = Float(rawA1 / rawA0)
        a2 = Float(rawA2 / rawA0)
    }

    /// RBJ cookbook low pass, high pass and notch (unity gain in the pass band).
    private mutating func configureCookbook(_ type: FilterType, centerFrequency: Float, sampleRate: Int, q: Float) {
        let w0 = 2.0 * Double.pi * Double(centerFrequency) / Double(sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2.0 * Double(max(q, 0.1)))
        let raw: (Double, Double, Double)
        switch type {
        case .lowPass: raw = ((1 - cosW0) / 2, 1 - cosW0, (1 - cosW0) / 2)
        case .highPass: raw = ((1 + cosW0) / 2, -(1 + cosW0), (1 + cosW0) / 2)
        default: raw = (1, -2 * cosW0, 1)
        }
        let a0 = 1 + alpha
        b0 = Float(raw.0 / a0)
        b1 = Float(raw.1 / a0)
        b2 = Float(raw.2 / a0)
        a1 = Float(-2 * cosW0 / a0)
        a2 = Float((1 - alpha) / a0)
    }

    /// Takes another filter's history, so new coefficients don't restart the filter from silence.
    mutating func copyState(from other: BiquadFilter) {
        x1 = other.x1; x2 = other.x2; y1 = other.y1; y2 = other.y2
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        if !y.isFinite {
            reset()
            return x
        }
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    /** Gain in dB of the configured filter at [targetFrequency]. */
    func frequencyResponse(_ targetFrequency: Float, sampleRate: Int) -> Float {
        if isIdentity || sampleRate <= 0 { return 0 }
        let w = 2.0 * Double.pi * Double(targetFrequency) / Double(sampleRate)
        let (cosW, cos2W, sinW, sin2W) = (cos(w), cos(2 * w), sin(w), sin(2 * w))
        let (fb0, fb1, fb2, fa1, fa2) = (Double(b0), Double(b1), Double(b2), Double(a1), Double(a2))
        let numReal = fb0 + fb1 * cosW + fb2 * cos2W
        let numImag = -fb1 * sinW - fb2 * sin2W
        let denReal = 1.0 + fa1 * cosW + fa2 * cos2W
        let denImag = -fa1 * sinW - fa2 * sin2W
        let denMagSq = denReal * denReal + denImag * denImag
        if denMagSq == 0 { return 0 }
        return Float(10 * log10((numReal * numReal + numImag * numImag) / denMagSq))
    }
}

/// One equaliser band exactly as the audio path applies it. The audio and the curve the
/// equaliser draws are both built from these through [BandFilter], so what is shown is heard.
struct BandSpec: Equatable, Sendable {
    var type: FilterType
    var frequencyHz: Float
    var gainDb: Float
    var q: Float
    /// dB per octave of a low or high pass: 12, 24 or 48. Ignored by the other types.
    var slope: Int = 12
    var enabled = true
}

/// A band as one to four cascaded biquads: a low or high pass of 24 or 48 dB/octave is a
/// Butterworth cascade (2 or 4 stages with fixed Qs); every other filter is one stage.
struct BandFilter {
    static let maxStages = 4
    static let slopes = [12, 24, 48]
    private var stages = [BiquadFilter](repeating: BiquadFilter(), count: maxStages)
    private(set) var stageCount = 0

    var isIdentity: Bool { stageCount == 0 }

    /// 12 dB/octave keeps the band's own Q (its resonance); steeper slopes are Butterworth.
    static func passQs(slope: Int, q: Float) -> [Float] {
        switch slope {
        case 24: [0.5412, 1.3066]
        case 48: [0.5098, 0.6013, 0.9000, 2.5629]
        default: [q]
        }
    }

    mutating func configure(_ spec: BandSpec, sampleRate: Int) {
        stageCount = 0
        guard spec.enabled, sampleRate > 0, !(spec.type.hasGain && spec.gainDb == 0) else { return }
        let nyquistSafe = Float(sampleRate) * Equalizer.maxBandToSampleRateRatio
        // Peaks, shelves and notches above what the stream carries do nothing; pass filters are
        // clamped instead (a high pass at 19 kHz on a 32 kHz stream still removes nearly everything).
        if !spec.type.isPass, spec.frequencyHz >= nyquistSafe { return }
        let frequency = min(spec.frequencyHz, nyquistSafe)
        let qs = spec.type.isPass ? Self.passQs(slope: spec.slope, q: spec.q) : [spec.q]
        for (index, q) in qs.enumerated() {
            stages[index].configure(centerFrequency: frequency, sampleRate: sampleRate, gainInDb: spec.gainDb, q: q, type: spec.type)
        }
        stageCount = qs.count
    }

    @inline(__always)
    mutating func process(_ sample: Float) -> Float {
        var x = sample
        var i = 0
        while i < stageCount { x = stages[i].process(x); i += 1 }
        return x
    }

    mutating func copyState(from other: BandFilter) {
        for i in 0..<Self.maxStages { stages[i].copyState(from: other.stages[i]) }
    }

    mutating func reset() {
        for i in 0..<Self.maxStages { stages[i].reset() }
    }

    func responseDb(_ frequencyHz: Float, sampleRate: Int) -> Float {
        var total: Float = 0
        for i in 0..<stageCount { total += stages[i].frequencyResponse(frequencyHz, sampleRate: sampleRate) }
        return total
    }

    /// The combined response of [bands] in dB at each of [frequencies].
    static func response(of bands: [BandSpec], at frequencies: [Float], sampleRate: Int) -> [Float] {
        let filters = bands.map { spec -> BandFilter in
            var filter = BandFilter()
            filter.configure(spec, sampleRate: sampleRate)
            return filter
        }
        return frequencies.map { hz in filters.reduce(0) { $0 + $1.responseDb(hz, sampleRate: sampleRate) } }
    }
}

/// A second-order Butterworth high- or low-pass (Q = 1/√2), for filter sweeps. Reconfiguring keeps
/// the state, so a cutoff moving in small steps sweeps smoothly.
struct PassFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    private static let butterworthQ = 0.7071067811865476
    private static let minCutoffHz: Float = 10
    private static let maxCutoffFraction: Float = 0.45

    mutating func configure(_ type: PassType, cutoffHz: Float, sampleRate: Int) {
        let nyquistSafe = Float(sampleRate) * Self.maxCutoffFraction
        let w0 = 2.0 * Double.pi * Double(cutoffHz.clamped(Self.minCutoffHz, nyquistSafe)) / Double(sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / (2.0 * Self.butterworthQ)
        let a0 = 1.0 + alpha
        let nb0, nb1: Double
        switch type {
        case .lowPass:
            nb0 = (1 - cosW) / 2
            nb1 = 1 - cosW
        case .highPass:
            nb0 = (1 + cosW) / 2
            nb1 = -(1 + cosW)
        }
        b0 = Float(nb0 / a0)
        b1 = Float(nb1 / a0)
        b2 = b0
        a1 = Float(-2 * cosW / a0)
        a2 = Float((1 - alpha) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        if !y.isFinite {
            reset()
            return x
        }
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}
