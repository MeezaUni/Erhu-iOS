import Foundation
import Observation

/// The equaliser settings (Android's SoundRepositoryImpl): every change reaches the audio path at
/// once, and is saved when it settles (a slider drag is written once, with its final value).
@MainActor
@Observable
final class SoundStore {
    private(set) var settings: SoundSettings
    @ObservationIgnored private let kernel: EqKernel
    @ObservationIgnored private let store = JSONStore<SoundSettings>(name: "sound.json")

    init(kernel: EqKernel) {
        self.kernel = kernel
        settings = store.load()?.repaired() ?? SoundSettings()
        kernel.apply(settings)
    }

    var runtimeState: EqRuntimeState { kernel.runtimeState(settings: settings) }

    func setEqEnabled(_ enabled: Bool) { change { $0.isEqEnabled = enabled } }

    func setMode(_ mode: EqMode) { change { $0.mode = mode } }

    /// Graphic mode: one of the 8 fixed bands' gain.
    func setGraphicGain(_ index: Int, _ gainDb: Float) {
        guard (0..<Equalizer.bandCount).contains(index) else { return }
        change {
            if $0.graphicGains.count != Equalizer.bandCount { $0.graphicGains = Array(repeating: 0, count: Equalizer.bandCount) }
            $0.graphicGains[index] = gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb)
            $0.graphicPresetId = ""
        }
    }

    func setBandGain(_ index: Int, _ gainDb: Float) {
        updateBand(index) { $0.gainDb = gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb) }
    }

    func setBandFrequency(_ index: Int, _ hz: Float) {
        updateBand(index) { $0.frequencyHz = hz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz) }
    }

    func setBandQ(_ index: Int, _ q: Float) {
        updateBand(index) { $0.q = q.clamped(Equalizer.minQ, Equalizer.maxQ) }
    }

    /// A pass filter starts as a gentle Butterworth slope; a notch starts narrow.
    func setFilterType(_ index: Int, _ type: FilterType) {
        updateBand(index) { band in
            guard band.filterType != type else { return }
            band.filterType = type
            if type.isPass {
                band.q = 0.707
                if !BandFilter.slopes.contains(band.slope) { band.slope = 12 }
            } else if type == .notch {
                band.q = 4
            }
        }
    }

    func setBandEnabled(_ index: Int, _ enabled: Bool) { updateBand(index) { $0.enabled = enabled } }

    func setBandSlope(_ index: Int, _ slope: Int) {
        guard BandFilter.slopes.contains(slope) else { return }
        updateBand(index) { $0.slope = slope }
    }

    func resetBand(_ index: Int) {
        guard (0..<Equalizer.bandCount).contains(index) else { return }
        updateBand(index) { $0 = SoundSettings.defaultBands()[index] }
    }

    func setActiveBandCount(_ count: Int) {
        let safe = count.clamped(Equalizer.minBandCount, Equalizer.bandCount)
        change {
            $0.activeBandCount = safe
            $0.selectedBandIndex = $0.selectedBandIndex.clamped(0, safe - 1)
            $0.activePresetId = ""
        }
    }

    /// Selecting a band is not a sound change: nothing is saved.
    func setSelectedBandIndex(_ index: Int) {
        settings.selectedBandIndex = index.clamped(0, settings.activeBandCount - 1)
    }

    /// A drag on the curve: frequency and (for filters with a gain) gain together. Bands may cross.
    func setBandFrequencyAndGain(_ index: Int, _ hz: Float, _ gainDb: Float) {
        updateBand(index) { band in
            band.frequencyHz = hz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)
            if band.filterType.hasGain { band.gainDb = gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb) }
        }
    }

    func applyPreset(_ id: String) {
        guard let preset = settings.allPresets.first(where: { $0.id == id }) else { return }
        change { settings in
            if preset.mode == .graphic {
                settings.graphicGains = (0..<Equalizer.bandCount).map { preset.bandGains.indices.contains($0) ? preset.bandGains[$0] : 0 }
                settings.graphicPresetId = id
            } else {
                settings.bands = preset.parametricBands()
                settings.activeBandCount = preset.bandCount.clamped(Equalizer.minBandCount, Equalizer.bandCount)
                settings.selectedBandIndex = settings.selectedBandIndex.clamped(0, settings.activeBandCount - 1)
                settings.activePresetId = id
            }
        }
    }

    func resetToFlat() { applyPreset(settings.mode == .graphic ? EqPreset.flat.id : EqPreset.parametricFlat.id) }

    func saveCustomPreset(_ name: String) {
        let trimmed = name.trimmed
        if trimmed.isEmpty { return }
        let id = "custom_\(UUID().uuidString.lowercased())"
        let preset: EqPreset
        if settings.mode == .graphic {
            preset = EqPreset(id: id, name: trimmed, bandGains: settings.graphicGains, isCustom: true, mode: .graphic)
        } else {
            let bands = settings.bands
            preset = EqPreset(
                id: id, name: trimmed, bandGains: bands.map(\.gainDb), bandFrequencies: bands.map(\.frequencyHz),
                bandQs: bands.map(\.q), filterTypes: bands.map(\.filterType), isCustom: true, mode: .parametric,
                bandCount: settings.activeBandCount, bandEnabled: bands.map(\.enabled), slopes: bands.map(\.slope)
            )
        }
        change {
            $0.customPresets.append(preset)
            if preset.mode == .graphic { $0.graphicPresetId = id } else { $0.activePresetId = id }
        }
    }

    func renameCustomPreset(_ id: String, _ name: String) {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty, let index = settings.customPresets.firstIndex(where: { $0.id == id }) else { return }
        change { $0.customPresets[index].name = trimmed }
    }

    func deleteCustomPreset(_ id: String) {
        guard settings.customPresets.contains(where: { $0.id == id }) else { return }
        change {
            $0.customPresets.removeAll { $0.id == id }
            if $0.activePresetId == id { $0.activePresetId = "" }
            if $0.graphicPresetId == id { $0.graphicPresetId = "" }
        }
    }

    private func updateBand(_ index: Int, _ edit: (inout BandConfig) -> Void) {
        guard settings.bands.indices.contains(index) else { return }
        change {
            edit(&$0.bands[index])
            $0.activePresetId = ""
        }
    }

    /// Saves at once (the app is going to the background).
    func persistNow() { store.saveNow(settings) }

    private func change(_ edit: (inout SoundSettings) -> Void) {
        edit(&settings)
        kernel.apply(settings)
        store.save(settings)
    }
}
