import SwiftUI

struct ReleaseCheckView: View {
    @State private var checker = ReleaseChecker.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            switch checker.state {
            case .idle: Text("Check GitHub Releases for a newer build.")
            case .checking: ProgressView("Checking releases…")
            case .current: Label("You have the latest published release", systemImage: "checkmark.circle")
            case .failed(let message): Text(message).foregroundStyle(.secondary)
            case .available(let release):
                Label("\(release.tag_name) is available", systemImage: "arrow.down.circle")
                    .font(.headline)
                if let notes = release.body?.nonBlank { Text(notes).font(.subheadline).lineLimit(8) }
                Link("Release notes", destination: release.html_url)
                if let url = release.download(animated: BuildVariant.animated) { Link("Download \(BuildVariant.animated ? "animated" : "static") IPA", destination: url) }
                Text("Install the IPA using SideStore or AltStore. Erhu cannot install itself.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { Task { await checker.check(manual: true) } } label: {
                Label("Check for updates", systemImage: "arrow.clockwise")
            }.disabled(checker.state == .checking)
            if let checkedAt = checker.checkedAt { Text("Last checked \(checkedAt.formatted())").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.lg)
    }
}
