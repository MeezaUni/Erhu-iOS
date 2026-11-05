import SwiftUI

/// Native sizing and press behaviour, with an explicit foreground for pale accents.
struct PaletteFilledButton: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(PaletteFilledButtonStyle())
    }
}

private struct PaletteFilledButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(palette.onFilledButton)
            .padding(.horizontal, size == .large ? 24 : 16)
            .padding(.vertical, size == .large ? 16 : 10)
            .background(palette.filledButton, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.outline.opacity(0.35), lineWidth: 1) }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A contrasting thumb and a rim stay visible even when the accent is almost white.
struct PaletteToggleStyle: ToggleStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 16)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? palette.filledButton : palette.surfaceVariant)
                    .overlay { Capsule().strokeBorder(palette.outline, lineWidth: 1) }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? palette.onFilledButton : palette.onSurface)
                            .frame(width: 25, height: 25)
                            .padding(3)
                    }
                    .frame(width: 51, height: 31)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(enabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}
