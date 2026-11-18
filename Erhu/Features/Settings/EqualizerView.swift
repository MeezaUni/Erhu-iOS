import SwiftUI

/// The equaliser: on / off, Graphic or Parametric, presets of that mode (save, rename and delete
/// your own), the response curve with draggable nodes, then the mode's own controls: Graphic's
/// 8 gains, or Parametric's 4 to 8 bands with each band's type, frequency, gain, slope and Q.
struct EqualizerView: View {
    @Environment(SoundStore.self) private var sound
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var renaming: EqPreset?
    @State private var renameText = ""
    @State private var enteringFrequency = false
    @State private var frequencyText = ""

    var body: some View {
        let settings = sound.settings
        let graphic = settings.mode == .graphic
        let selected = settings.selectedBandIndex.clamped(0, settings.activeBandCount - 1)
        let band = settings.bands.indices.contains(selected) ? settings.bands[selected] : SoundSettings.defaultBands()[selected]
        Form {
            Section {
                Toggle("Equalizer", isOn: Binding(get: { settings.isEqEnabled }, set: { sound.setEqEnabled($0) }))
            }.toolSectionAppearance()
            Section("Preset & curve") {
                Picker("Mode", selection: Binding(get: { settings.mode }, set: { sound.setMode($0) })) {
                    Text("Graphic").tag(EqMode.graphic)
                    Text("Parametric").tag(EqMode.parametric)
                }
                .pickerStyle(.segmented)
                presetRow(settings)
                EqCurve(settings: settings, selected: graphic ? -1 : selected,
                        onSelect: { if !graphic { sound.setSelectedBandIndex($0) } },
                        onDrag: { index, hz, gain in
                            if graphic { sound.setGraphicGain(index, gain) } else { sound.setBandFrequencyAndGain(index, hz, gain) }
                        })
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.sm, bottom: Spacing.sm, trailing: Spacing.sm))
            }.toolSectionAppearance()
            .disabled(!settings.isEqEnabled)
            if graphic {
                Section("Bands") {
                    ForEach(0..<Equalizer.bandCount, id: \.self) { index in
                        let gain = settings.graphicGains.indices.contains(index) ? settings.graphicGains[index] : 0
                        labeledSlider(formatFrequency(Equalizer.bandFrequencies[index]), value: formatGain(gain),
                                      binding: Binding(get: { gain }, set: { sound.setGraphicGain(index, ($0 * 2).rounded() / 2) }),
                                      range: Equalizer.minGainDb...Equalizer.maxGainDb)
                    }
                }.toolSectionAppearance()
                .disabled(!settings.isEqEnabled)
            } else {
                Section("Bands") {
                    Stepper("Active bands: \(settings.activeBandCount)", value: Binding(get: { settings.activeBandCount }, set: { sound.setActiveBandCount($0) }),
                            in: Equalizer.minBandCount...Equalizer.bandCount)
                    Picker("Band", selection: Binding(get: { selected }, set: { sound.setSelectedBandIndex($0) })) {
                        ForEach(0..<settings.activeBandCount, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }.toolSectionAppearance()
                .disabled(!settings.isEqEnabled)
                Section("Band \(selected + 1)") {
                    bandControls(band, index: selected)
                }.toolSectionAppearance()
                .disabled(!settings.isEqEnabled)
            }
        }.modifier(ToolPageAppearance())
        .navigationTitle("Equalizer")
        .alert("Save custom preset", isPresented: $savingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                sound.saveCustomPreset(presetName)
                presetName = ""
            }
        }
        .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Preset name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { sound.renameCustomPreset(renaming.id, renameText) }
                renaming = nil
            }
        }
        .alert("Center frequency", isPresented: $enteringFrequency) {
            TextField("Hz (20 – 20000)", text: $frequencyText).keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let hz = Float(frequencyText.replacingOccurrences(of: ",", with: ".")),
                   (Equalizer.minFreqHz...Equalizer.maxFreqHz).contains(hz) {
                    sound.setBandFrequency(selected, hz)
                }
            }
        } message: {
            Text("Enter a frequency from 20 Hz to 20 kHz.")
        }
    }

    @ViewBuilder
    private func presetRow(_ settings: SoundSettings) -> some View {
        let presets = settings.presetsForMode
        let customs = presets.filter(\.isCustom)
        HStack {
            Menu {
                ForEach(presets) { preset in
                    Button(preset.name) { sound.applyPreset(preset.id) }
                }
                if !customs.isEmpty {
                    Menu("Rename a custom preset") {
                        ForEach(customs) { preset in
                            Button(preset.name) { renameText = preset.name; renaming = preset }
                        }
                    }
                    Menu("Delete a custom preset") {
                        ForEach(customs) { preset in
                            Button(preset.name, role: .destructive) { sound.deleteCustomPreset(preset.id) }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Preset")
                    Spacer()
                    Text(presets.first { $0.id == settings.presetIdForMode }?.name ?? String(localized: "Custom")).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { savingPreset = true } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Save custom preset")
            Button { sound.resetToFlat() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset to flat")
        }
    }

    @ViewBuilder
    private func bandControls(_ band: BandConfig, index: Int) -> some View {
        Toggle("Band on", isOn: Binding(get: { band.enabled }, set: { sound.setBandEnabled(index, $0) }))
        Group {
            Picker("Filter type", selection: Binding(get: { band.filterType }, set: { sound.setFilterType(index, $0) })) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Center frequency")
                    Spacer()
                    Button(formatPreciseFrequency(band.frequencyHz)) {
                        frequencyText = String(Int(band.frequencyHz.rounded()))
                        enteringFrequency = true
                    }
                    .buttonStyle(.borderless)
                    .monospacedDigit()
                    .accessibilityHint("Enter an exact frequency")
                }
                Slider(value: Binding(get: { frequencyToNormalized(band.frequencyHz) },
                                      set: { sound.setBandFrequency(index, normalizedToFrequency($0)) }), in: 0...1)
            }
            if band.filterType.hasGain {
                labeledSlider(String(localized: "Gain"), value: formatGain(band.gainDb),
                              binding: Binding(get: { band.gainDb }, set: { sound.setBandGain(index, ($0 * 10).rounded() / 10) }),
                              range: Equalizer.minGainDb...Equalizer.maxGainDb)
            }
            if band.filterType.isPass {
                Picker("Slope", selection: Binding(get: { band.slope }, set: { sound.setBandSlope(index, $0) })) {
                    ForEach(BandFilter.slopes, id: \.self) { Text("\($0) dB/oct").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            // Steeper pass filters are fixed Butterworth cascades: Q only shapes the 12 dB/octave slope.
            if !band.filterType.isPass || band.slope == 12 {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    labeledSlider("Q-factor (sharpness)", value: String(format: "%.2f", band.q),
                                  binding: Binding(get: { qToNormalized(band.q) }, set: { sound.setBandQ(index, normalizedToQ($0)) }), range: 0...1)
                    Text(band.filterType.isPass ? "Higher Q adds a resonant peak at the cutoff" : "Lower Q = wider band, higher Q = narrower band")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!band.enabled)
        Button { sound.resetBand(index) } label: { Label("Reset band", systemImage: "arrow.counterclockwise") }
    }

    private func labeledSlider(_ label: String, value: String, binding: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(Color.accentColor).monospacedDigit()
            }
            Slider(value: binding, in: range)
        }
    }

    private func frequencyToNormalized(_ hz: Float) -> Float {
        let low = log10(Equalizer.minFreqHz), high = log10(Equalizer.maxFreqHz)
        return (log10(hz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)) - low) / (high - low)
    }

    private func normalizedToFrequency(_ norm: Float) -> Float {
        let low = log10(Equalizer.minFreqHz), high = log10(Equalizer.maxFreqHz)
        return pow(10, low + norm.clamped(0, 1) * (high - low)).clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)
    }

    /// Q on a log scale, 0.1 to 10, so narrow and wide settings get equal room.
    private func qToNormalized(_ q: Float) -> Float {
        let low = log10(Equalizer.minQ), high = log10(Equalizer.maxQ)
        return (log10(q.clamped(Equalizer.minQ, Equalizer.maxQ)) - low) / (high - low)
    }

    private func normalizedToQ(_ norm: Float) -> Float {
        let low = log10(Equalizer.minQ), high = log10(Equalizer.maxQ)
        return (pow(10, low + norm.clamped(0, 1) * (high - low)) * 100).rounded() / 100
    }

    private func formatFrequency(_ hz: Float) -> String { hz >= 1000 ? "\(Int((hz / 1000).rounded())) kHz" : "\(Int(hz.rounded())) Hz" }

    /// 1 Hz below 1 kHz, 10 Hz above: "250 Hz", "2.45 kHz".
    private func formatPreciseFrequency(_ hz: Float) -> String {
        guard hz >= 1000 else { return "\(Int(hz.rounded())) Hz" }
        var text = String(format: "%.2f", hz / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) kHz"
    }

    private func formatGain(_ db: Float) -> String { (db > 0 ? "+" : "") + String(format: "%.1f dB", db) }
}

/// The combined response of the active bands, with a draggable numbered node per band.
private struct EqCurve: View {
    let settings: SoundSettings
    let selected: Int
    let onSelect: (Int) -> Void
    let onDrag: (Int, Float, Float) -> Void
    @Environment(\.palette) private var palette
    @State private var dragged: Int?

    private static let minFreq: Float = 20
    private static let maxFreq: Float = 20_000
    private static let points: [Float] = (0..<120).map { i in
        let low = log10(minFreq), high = log10(maxFreq)
        return pow(10, low + Float(i) / 119 * (high - low))
    }

    var body: some View {
        let response = EqKernel.response(of: settings, at: Self.points)
        let bands = settings.effectiveBands()
        let nodes = bands.map { band -> (hz: Float, db: Float, on: Bool) in
            // Pass filters and notches have no gain: their node sits on the curve.
            let db = band.type.hasGain ? band.gainDb : EqKernel.response(of: settings, at: [band.frequencyHz])[0]
            return (band.frequencyHz, db, band.enabled)
        }
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                for db: Float in [12, 6, 0, -6, -12] {
                    var line = Path()
                    let y = gainToY(db, size.height)
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(palette.outline.opacity(db == 0 ? 0.8 : 0.35)), lineWidth: db == 0 ? 1.5 : 1)
                }
                for hz: Float in [60, 250, 1000, 4000, 12000] {
                    var line = Path()
                    let x = freqToX(hz, size.width)
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(palette.outline.opacity(0.35)), lineWidth: 1)
                }
                var curve = Path()
                for (i, hz) in Self.points.enumerated() {
                    let point = CGPoint(x: freqToX(hz, size.width), y: gainToY(response[i], size.height))
                    if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(palette.primary), lineWidth: 3)
                for (index, node) in nodes.enumerated() {
                    let center = CGPoint(x: freqToX(node.hz, size.width), y: gainToY(node.db, size.height))
                    let isSelected = index == selected
                    context.opacity = node.on ? 1 : 0.4
                    if isSelected {
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)),
                                     with: .color(palette.surfaceVariant))
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(palette.primary))
                    } else {
                        context.stroke(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                                       with: .color(palette.primary), lineWidth: 2)
                    }
                    context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? palette.onPrimary : palette.primary), at: center)
                }
                context.opacity = 1
            }
            .background(palette.onSurface.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
            // The curve owns its drag: moving a node never scrolls the page.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragged == nil {
                            dragged = nearest(to: value.startLocation, in: size, nodes: nodes)
                            if let dragged { onSelect(dragged) }
                        }
                        guard let dragged, value.translation != .zero else { return }
                        onDrag(dragged, xToFreq(value.location.x, size.width), yToGain(value.location.y, size.height))
                    }
                    .onEnded { _ in dragged = nil }
            )
            .disabled(!settings.isEqEnabled)
            .accessibilityLabel("Equalizer curve")
        }
    }

    private func nearest(to point: CGPoint, in size: CGSize, nodes: [(hz: Float, db: Float, on: Bool)]) -> Int? {
        var best: Int?
        var bestDistance: CGFloat = 48
        for (index, node) in nodes.enumerated() {
            let distance = hypot(point.x - freqToX(node.hz, size.width), point.y - gainToY(node.db, size.height))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func freqToX(_ hz: Float, _ width: CGFloat) -> CGFloat {
        let low = log10(Self.minFreq), high = log10(Self.maxFreq)
        return CGFloat((log10(hz.clamped(Self.minFreq, Self.maxFreq)) - low) / (high - low)) * width
    }

    private func xToFreq(_ x: CGFloat, _ width: CGFloat) -> Float {
        let low = log10(Self.minFreq), high = log10(Self.maxFreq)
        return pow(10, low + Float(x / max(width, 1)).clamped(0, 1) * (high - low))
    }

    private func gainToY(_ db: Float, _ height: CGFloat) -> CGFloat {
        CGFloat((Equalizer.maxGainDb - db.clamped(Equalizer.minGainDb, Equalizer.maxGainDb)) / (Equalizer.maxGainDb - Equalizer.minGainDb)) * height
    }

    private func yToGain(_ y: CGFloat, _ height: CGFloat) -> Float {
        (Equalizer.maxGainDb - Float(y / max(height, 1)) * (Equalizer.maxGainDb - Equalizer.minGainDb)).clamped(Equalizer.minGainDb, Equalizer.maxGainDb)
    }
}
