import Foundation

/// The equaliser's fixed layout (same as Android's CustomEqAudioProcessor).
enum Equalizer {
    static let bandCount = 8
    static let minBandCount = 4
    static let defaultQ: Float = 1.414
    static let minQ: Float = 0.1
    static let maxQ: Float = 10
    static let minFreqHz: Float = 20
    static let maxFreqHz: Float = 20_000
    static let minGainDb: Float = -15
    static let maxGainDb: Float = 15
    static let bandFrequencies: [Float] = [60, 150, 400, 1000, 2400, 6000, 12000, 16000]
    /// Above this share of the sample rate a band is skipped.
    static let maxBandToSampleRateRatio: Float = 0.45
}

struct BandConfig: Equatable, Codable {
    var frequencyHz: Float
    var gainDb: Float
    var q: Float = Equalizer.defaultQ
    var filterType: FilterType = .peaking
    /// A band switched off keeps its settings but does nothing.
    var enabled = true
    /// dB per octave of a low or high pass: 12, 24 or 48.
    var slope = 12

    init(frequencyHz: Float, gainDb: Float, q: Float = Equalizer.defaultQ, filterType: FilterType = .peaking,
         enabled: Bool = true, slope: Int = 12) {
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
        self.q = q
        self.filterType = filterType
        self.enabled = enabled
        self.slope = slope
    }

    /// Files saved before a field existed keep its default; an unknown filter type is a peak.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequencyHz = try c.decode(Float.self, forKey: .frequencyHz)
        gainDb = try c.decode(Float.self, forKey: .gainDb)
        q = (try? c.decodeIfPresent(Float.self, forKey: .q)) ?? Equalizer.defaultQ
        filterType = (try? c.decodeIfPresent(FilterType.self, forKey: .filterType)) ?? .peaking
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        slope = (try? c.decodeIfPresent(Int.self, forKey: .slope)) ?? 12
    }

    var spec: BandSpec { BandSpec(type: filterType, frequencyHz: frequencyHz, gainDb: gainDb, q: q, slope: slope, enabled: enabled) }
}

/// Graphic: 8 fixed bands, gain only, the classic presets. Parametric: 4 to 8 freely shaped bands.
enum EqMode: String, Codable, CaseIterable {
    case graphic, parametric
}

struct EqPreset: Equatable, Codable, Identifiable {
    let id: String
    var name: String
    var bandGains: [Float]
    var bandFrequencies: [Float] = Equalizer.bandFrequencies
    var bandQs: [Float] = Array(repeating: Equalizer.defaultQ, count: Equalizer.bandCount)
    var filterTypes: [FilterType] = Array(repeating: .peaking, count: Equalizer.bandCount)
    var isCustom = false
    /// Graphic presets set the 8 fixed bands' gains; parametric ones set whole bands.
    var mode: EqMode = .graphic
    var bandCount = Equalizer.bandCount
    var bandEnabled: [Bool] = Array(repeating: true, count: Equalizer.bandCount)
    var slopes: [Int] = Array(repeating: 12, count: Equalizer.bandCount)

    init(id: String, name: String, bandGains: [Float], bandFrequencies: [Float] = Equalizer.bandFrequencies,
         bandQs: [Float] = Array(repeating: Equalizer.defaultQ, count: Equalizer.bandCount),
         filterTypes: [FilterType] = Array(repeating: .peaking, count: Equalizer.bandCount), isCustom: Bool = false,
         mode: EqMode = .graphic, bandCount: Int = Equalizer.bandCount,
         bandEnabled: [Bool] = Array(repeating: true, count: Equalizer.bandCount),
         slopes: [Int] = Array(repeating: 12, count: Equalizer.bandCount)) {
        self.id = id
        self.name = name
        self.bandGains = bandGains
        self.bandFrequencies = bandFrequencies
        self.bandQs = bandQs
        self.filterTypes = filterTypes
        self.isCustom = isCustom
        self.mode = mode
        self.bandCount = bandCount
        self.bandEnabled = bandEnabled
        self.slopes = slopes
    }

    /// Presets saved before modes existed set whole bands: they are parametric.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bandGains = try c.decode([Float].self, forKey: .bandGains)
        bandFrequencies = (try? c.decodeIfPresent([Float].self, forKey: .bandFrequencies)) ?? Equalizer.bandFrequencies
        bandQs = (try? c.decodeIfPresent([Float].self, forKey: .bandQs)) ?? Array(repeating: Equalizer.defaultQ, count: Equalizer.bandCount)
        filterTypes = (try? c.decodeIfPresent([FilterType].self, forKey: .filterTypes)) ?? Array(repeating: .peaking, count: Equalizer.bandCount)
        isCustom = (try? c.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
        mode = (try? c.decodeIfPresent(EqMode.self, forKey: .mode)) ?? .parametric
        bandCount = (try? c.decodeIfPresent(Int.self, forKey: .bandCount)) ?? Equalizer.bandCount
        bandEnabled = (try? c.decodeIfPresent([Bool].self, forKey: .bandEnabled)) ?? Array(repeating: true, count: Equalizer.bandCount)
        slopes = (try? c.decodeIfPresent([Int].self, forKey: .slopes)) ?? Array(repeating: 12, count: Equalizer.bandCount)
    }

    /// The parametric bands this preset sets (all 8; [bandCount] of them are active).
    func parametricBands() -> [BandConfig] {
        (0..<Equalizer.bandCount).map { i in
            BandConfig(
                frequencyHz: bandFrequencies.indices.contains(i) ? bandFrequencies[i] : Equalizer.bandFrequencies[i],
                gainDb: bandGains.indices.contains(i) ? bandGains[i] : 0,
                q: bandQs.indices.contains(i) ? bandQs[i] : Equalizer.defaultQ,
                filterType: filterTypes.indices.contains(i) ? filterTypes[i] : .peaking,
                enabled: bandEnabled.indices.contains(i) ? bandEnabled[i] : true,
                slope: slopes.indices.contains(i) ? slopes[i] : 12
            )
        }
    }

    static let flat = EqPreset(id: "preset_flat", name: String(localized: "Flat"), bandGains: [0, 0, 0, 0, 0, 0, 0, 0])
    static let bassBooster = EqPreset(id: "preset_bass_booster", name: String(localized: "Bass Booster"), bandGains: [6, 5, 3, 1, 0, 0, 0, 0])
    static let trebleBooster = EqPreset(id: "preset_treble_booster", name: String(localized: "Treble Booster"), bandGains: [0, 0, 0, 0, 1, 3, 5, 6])
    static let rock = EqPreset(id: "preset_rock", name: String(localized: "Rock"), bandGains: [5, 3, -1, -2, 1, 3, 5, 6])
    static let pop = EqPreset(id: "preset_pop", name: String(localized: "Pop"), bandGains: [-1, 1, 3, 4, 4, 3, 1, -1])
    static let jazz = EqPreset(id: "preset_jazz", name: String(localized: "Jazz"), bandGains: [3, 2, 1, 2, -1, -1, 2, 3])
    static let vocal = EqPreset(id: "preset_vocal", name: String(localized: "Vocal"), bandGains: [-2, -1, 2, 5, 4, 2, 0, -2])
    static let acoustic = EqPreset(id: "preset_acoustic", name: String(localized: "Acoustic"), bandGains: [4, 3, 1, 2, 2, 3, 3, 2])

    static let defaults = [flat, bassBooster, trebleBooster, rock, pop, jazz, vocal, acoustic]

    /// A parametric preset from its bands; the remaining slots keep their default, flat bands.
    private static func parametric(_ id: String, _ name: String, _ bands: BandConfig...) -> EqPreset {
        var all = SoundSettings.defaultBands()
        for (i, band) in bands.enumerated() { all[i] = band }
        return EqPreset(id: id, name: name, bandGains: all.map(\.gainDb), bandFrequencies: all.map(\.frequencyHz),
                        bandQs: all.map(\.q), filterTypes: all.map(\.filterType), mode: .parametric,
                        bandCount: bands.count.clamped(Equalizer.minBandCount, Equalizer.bandCount),
                        bandEnabled: all.map(\.enabled), slopes: all.map(\.slope))
    }
    private static func peak(_ hz: Float, _ db: Float, _ q: Float = 1) -> BandConfig { BandConfig(frequencyHz: hz, gainDb: db, q: q) }
    private static func lowShelf(_ hz: Float, _ db: Float) -> BandConfig { BandConfig(frequencyHz: hz, gainDb: db, q: 0.7, filterType: .lowShelf) }
    private static func highShelf(_ hz: Float, _ db: Float) -> BandConfig { BandConfig(frequencyHz: hz, gainDb: db, q: 0.7, filterType: .highShelf) }
    private static func highPass(_ hz: Float, _ slope: Int) -> BandConfig {
        BandConfig(frequencyHz: hz, gainDb: 0, q: 0.707, filterType: .highPass, slope: slope)
    }

    static let parametricFlat = parametric("preset_p_flat", String(localized: "Flat"), peak(100, 0), peak(400, 0), peak(2500, 0), peak(8000, 0))

    static let parametricDefaults: [EqPreset] = [
        parametricFlat,
        parametric("preset_p_warm_bass", String(localized: "Warm Bass"), highPass(25, 24), lowShelf(110, 5), peak(300, -1.5, 1.2), peak(3500, 0)),
        parametric("preset_p_vocal_presence", String(localized: "Vocal Presence"), highPass(80, 12), peak(250, -2, 1), peak(3000, 3, 1.2), highShelf(10_000, 1.5)),
        parametric("preset_p_air", String(localized: "Air & Sparkle"), peak(250, -1, 0.9), peak(1000, 0), peak(5000, 1, 1.5), highShelf(11_000, 4)),
        parametric("preset_p_loudness", String(localized: "Loudness"), lowShelf(90, 5), peak(1000, -2, 0.8), peak(3000, 0), highShelf(9000, 4)),
        parametric("preset_p_de_harsh", String(localized: "De-harsh"), peak(200, 0), peak(1000, 0), peak(3500, -3, 2), peak(7500, -2.5, 3)),
        parametric("preset_p_rumble_cut", String(localized: "Rumble & Hiss Cut"), highPass(40, 48), peak(400, 0), peak(2500, 0),
                   BandConfig(frequencyHz: 16_000, gainDb: 0, q: 0.707, filterType: .lowPass)),
    ]
}

struct SoundSettings: Equatable, Codable {
    var isEqEnabled = true
    var bands: [BandConfig] = SoundSettings.defaultBands()
    var activeBandCount = Equalizer.bandCount
    var selectedBandIndex = 0
    var activePresetId = EqPreset.flat.id
    var customPresets: [EqPreset] = []
    var mode: EqMode = .parametric
    /// The Graphic mode's 8 gains, kept apart from the parametric bands so switching loses neither.
    var graphicGains: [Float] = Array(repeating: 0, count: Equalizer.bandCount)
    var graphicPresetId = EqPreset.flat.id

    init() {}

    /// Files saved before a field existed keep its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEqEnabled)) ?? true
        bands = (try? c.decodeIfPresent([BandConfig].self, forKey: .bands)) ?? SoundSettings.defaultBands()
        activeBandCount = (try? c.decodeIfPresent(Int.self, forKey: .activeBandCount)) ?? Equalizer.bandCount
        selectedBandIndex = (try? c.decodeIfPresent(Int.self, forKey: .selectedBandIndex)) ?? 0
        activePresetId = (try? c.decodeIfPresent(String.self, forKey: .activePresetId)) ?? EqPreset.flat.id
        customPresets = (try? c.decodeIfPresent([EqPreset].self, forKey: .customPresets)) ?? []
        mode = (try? c.decodeIfPresent(EqMode.self, forKey: .mode)) ?? .parametric
        graphicGains = (try? c.decodeIfPresent([Float].self, forKey: .graphicGains)) ?? Array(repeating: 0, count: Equalizer.bandCount)
        graphicPresetId = (try? c.decodeIfPresent(String.self, forKey: .graphicPresetId)) ?? EqPreset.flat.id
    }

    var allPresets: [EqPreset] { EqPreset.defaults + EqPreset.parametricDefaults + customPresets }

    /// The presets of the mode on screen.
    var presetsForMode: [EqPreset] {
        mode == .graphic
            ? EqPreset.defaults + customPresets.filter { $0.mode == .graphic }
            : EqPreset.parametricDefaults + customPresets.filter { $0.mode == .parametric }
    }

    var presetIdForMode: String { mode == .graphic ? graphicPresetId : activePresetId }

    /// The bands the audio path applies in the current mode.
    func effectiveBands() -> [BandSpec] {
        if mode == .graphic {
            return (0..<Equalizer.bandCount).map { i in
                BandSpec(type: .peaking, frequencyHz: Equalizer.bandFrequencies[i],
                         gainDb: graphicGains.indices.contains(i) ? graphicGains[i] : 0, q: Equalizer.defaultQ)
            }
        }
        return bands.prefix(activeBandCount).map(\.spec)
    }

    static func defaultBands() -> [BandConfig] {
        Equalizer.bandFrequencies.map { BandConfig(frequencyHz: $0, gainDb: 0) }
    }

    /// Anything a stored file could hold that the app could not have produced is repaired
    /// (Android's PersistedSoundSettings.toSoundSettings).
    func repaired() -> SoundSettings {
        let count = Equalizer.bandCount
        let customs = customPresets
            .filter { $0.bandGains.count == count && !$0.id.isBlank }
            .map { preset -> EqPreset in
                var p = preset
                if p.bandFrequencies.count != count { p.bandFrequencies = Equalizer.bandFrequencies }
                if p.bandQs.count != count { p.bandQs = Array(repeating: Equalizer.defaultQ, count: count) }
                if p.filterTypes.count != count { p.filterTypes = Array(repeating: .peaking, count: count) }
                if p.bandEnabled.count != count { p.bandEnabled = Array(repeating: true, count: count) }
                if p.slopes.count != count { p.slopes = Array(repeating: 12, count: count) }
                p.bandCount = p.bandCount.clamped(Equalizer.minBandCount, count)
                p.isCustom = true
                return p
            }
        var out = self
        out.bands = bands.count == count ? bands : SoundSettings.defaultBands()
        out.customPresets = customs
        out.activeBandCount = activeBandCount.clamped(Equalizer.minBandCount, count)
        out.selectedBandIndex = selectedBandIndex.clamped(0, out.activeBandCount - 1)
        // "" is an edited, unnamed setting.
        let known = Set((EqPreset.defaults + EqPreset.parametricDefaults + customs).map(\.id) + [""])
        if !known.contains(activePresetId) { out.activePresetId = EqPreset.flat.id }
        if !known.contains(graphicPresetId) { out.graphicPresetId = EqPreset.flat.id }
        if graphicGains.count != count { out.graphicGains = Array(repeating: 0, count: count) }
        out.bands = out.bands.map { band in
            var b = band
            if !BandFilter.slopes.contains(b.slope) { b.slope = 12 }
            return b
        }
        return out
    }
}
