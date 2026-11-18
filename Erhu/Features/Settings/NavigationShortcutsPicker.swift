import SwiftUI

/// Chooses the tab bar's shortcuts (onboarding and Settings): Home stays first; up to three
/// others are added in the order they are tapped, and tapping one again removes it. Sections
/// left out stay in the side menu.
struct NavigationShortcutsPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    var body: some View {
        let chosen = settings.navigationShortcuts
        VStack(alignment: .leading, spacing: Spacing.md) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.sm)], spacing: Spacing.sm) {
                ForEach(settings.shortcutChoices) { section in
                    let position = chosen.firstIndex(of: section)
                    let full = position == nil && chosen.count >= AppSettings.shortcutLimit
                    Button { settings.toggleShortcut(section) } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: position == nil ? section.icon : section.selectedIcon)
                                .frame(width: 22)
                            Text(section.label).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let position {
                                Text("\(position + 2)")
                                    .font(.caption.weight(.bold)).monospacedDigit()
                                    .foregroundStyle(palette.onPrimary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(palette.primary))
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .frame(minHeight: 48)
                        .foregroundStyle(position == nil ? palette.onSurface : palette.primary)
                        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                            .fill(position == nil ? palette.onSurface.opacity(0.06) : palette.primary.opacity(0.16)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(full)
                    .opacity(full ? 0.45 : 1)
                    .accessibilityValue(position.map { String(localized: "Shortcut \($0 + 2)") } ?? String(localized: "Not in the tab bar"))
                }
            }
            Text("Preview").font(.caption.weight(.medium)).foregroundStyle(palette.onSurfaceVariant)
            HStack(spacing: 0) {
                ForEach(settings.visibleSections) { section in
                    VStack(spacing: 2) {
                        Image(systemName: section == .home ? section.selectedIcon : section.icon)
                        Text(section.label).font(.caption2.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(section == .home ? palette.primary : palette.onSurface)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
            .padding(.horizontal, 4)
            .background(Capsule().fill(palette.onSurface.opacity(0.06)))
            .animation(.smooth(duration: 0.2), value: settings.visibleSections)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Tab bar preview"))
        }
    }
}
