import SwiftUI

struct AppUpdatePrompt: View {
    let release: AppRelease
    let checker: ReleaseChecker
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Label("An update is available", systemImage: "arrow.down.circle.fill").font(.title2.bold())
                    Text(release.name?.nonBlank ?? release.tag_name).font(.headline)
                    Text(release.tag_name).font(.caption).foregroundStyle(.secondary)
                    if let published = release.published_at, let date = ISO8601DateFormatter().date(from: published) {
                        Text("Released " + date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(release.body?.nonBlank ?? "A newer version of Erhu is ready to download."))
                        .textSelection(.enabled)
                    Link("View release on GitHub", destination: release.html_url)
                    Text("Download the IPA for your current artwork variant and install it with your usual iOS installer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.lg)
            }
            .background(palette.background)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Spacing.sm) {
                    if let url = release.download(animated: BuildVariant.animated) {
                        Button { openURL(url); checker.dismissPrompt() } label: {
                            Label("Download update", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                                .foregroundStyle(palette.onFilledButton)
                        }.modifier(PaletteFilledButton()).tint(palette.filledButton)
                    }
                    Button("Skip for now") { checker.dismissPrompt() }
                    Button("Do not show this version again") { checker.dismissPrompt(ignore: true) }
                        .font(.footnote)
                }.controlSize(.large).padding(Spacing.lg).background(.regularMaterial)
            }
            .navigationTitle("Erhu update").navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
