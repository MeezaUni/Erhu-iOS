import SwiftUI

/// One appearance for tools and settings, regardless of which navigation link opened them.
struct ToolPageAppearance: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(palette.onSurface)
            .tint(palette.primary)
            .background(palette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ToolSectionAppearance: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.listRowBackground(palette.surface) }
}

extension View {
    func toolSectionAppearance() -> some View { modifier(ToolSectionAppearance()) }
}
