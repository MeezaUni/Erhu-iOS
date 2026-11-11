import SwiftUI

/// Settings actions are rows with one consistent hit area, not automatically styled pills.
struct SettingsActionLabel: View {
    let title: String
    let icon: String
    var accessory = "chevron.right"
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(ui: title)
                .font(.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: accessory)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.onSurfaceVariant)
                .accessibilityHidden(true)
        }
        .foregroundStyle(palette.onSurface)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}
