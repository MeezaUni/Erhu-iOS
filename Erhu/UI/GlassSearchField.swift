import SwiftUI

/// The same floating search control in global search and section-local pull-down search.
struct GlassSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState.Binding var focused: Bool
    let close: () -> Void
    var identifier = "librarySearchField"

    var body: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).submitLabel(.search).onSubmit { focused = false }
                    .accessibilityIdentifier(identifier)
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.md).frame(minHeight: 48)
            .glassSurface(cornerRadius: 28)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
            Button { focused = false; close() } label: {
                Image(systemName: "xmark").font(.title3).frame(width: 48, height: 48)
            }.buttonStyle(.plain).glassSurface(cornerRadius: 24)
                .accessibilityLabel("Close search")
        }
    }
}
