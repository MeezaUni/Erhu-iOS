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
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                        .accessibilityIdentifier("searchClearButton")
                }
            }
            .padding(.horizontal, Spacing.md).frame(minHeight: 48)
            .background { Color.clear.glassSurface(cornerRadius: 28).allowsHitTesting(false) }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)).allowsHitTesting(false))
            Button { focused = false; close() } label: {
                Image(systemName: "xmark").font(.title3).frame(width: 48, height: 48)
            }.buttonStyle(.plain)
                .background { Color.clear.glassSurface(cornerRadius: 24).allowsHitTesting(false) }
                .contentShape(Circle())
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("searchCloseButton")
        }
    }
}
