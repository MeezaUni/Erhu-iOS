import SwiftUI

struct ArtworkUpgradeView: View {
    let kind: ArtworkUpgradeKind
    @Environment(LibraryStore.self) private var library
    @Environment(ArtworkFetcherStore.self) private var fetcher
    @State private var store = ArtworkUpgradeStore()
    @State private var preview: ArtworkPreview?
    @State private var selected: ArtworkUpgrade?
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Find a larger version of your existing image. Only likely same-image matches appear here; review before replacing. Your current artwork stays until you apply a match. Saved images fit within \(TagWriter.maxArtworkPixels) pixels.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.scanning {
                    ProgressView(value: Double(store.checked), total: Double(max(store.total, 1)))
                    Text("Checked \(store.checked) of \(store.total)").font(.caption)
                    Button("Stop search", role: .cancel) { store.cancel() }
                } else {
                    Button(store.finished ? "Search again" : "Find higher-resolution matches") {
                        message = nil
                        store.scan(kind, library: library, search: fetcher.search)
                    }
                    if store.finished {
                        Text("Checked \(store.checked). \(store.results.count) upgrade\(store.results.count == 1 ? "" : "s") to review. Some sources may have no matching larger image.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.skipped > 0 { Text("\(store.skipped) images or requests could not be checked.").font(.caption).foregroundStyle(.secondary) }
                }
                if let message { Text(message).font(.footnote) }
            }.toolSectionAppearance()
            Section("Higher-resolution matches") {
                ForEach(store.results) { result in
                    Button { Task { await open(result) } } label: {
                        HStack(spacing: Spacing.md) {
                            if let image = result.thumbnail {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                                    .frame(width: 48, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading) {
                                Text(result.target.name).foregroundStyle(.primary)
                                Text("\(result.originalFacts.resolution) → \(result.candidate.image?.resolution ?? "larger")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Likely same image · Review").font(.caption)
                            }
                        }
                    }.buttonStyle(.plain).disabled(loading || saving)
                }
                if store.finished && store.results.isEmpty { Text("No larger same-image matches to review.").foregroundStyle(.secondary) }
            }.toolSectionAppearance()
        }
        .modifier(ToolPageAppearance())
        .navigationTitle(kind == .albums ? "Upgrade album covers" : "Upgrade artist photos")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView("Loading full image…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onDisappear { store.cancel() }
        .sheet(item: $preview) { item in
            ArtworkPreviewView(preview: item, saving: saving) {
                Task {
                    guard let result = selected, let candidate = item.candidate else { return }
                    saving = true
                    let success: Bool
                    switch result.target {
                    case .album(let album): success = await fetcher.applyCover(candidate, image: item.data, to: album)
                    case .artist(let artist): success = await fetcher.applyPhoto(candidate, image: item.data, to: artist)
                    }
                    saving = false
                    if success { store.remove(result); preview = nil; message = "Higher-resolution artwork saved." }
                    else { preview = nil; message = "Couldn’t save the artwork. Try again." }
                }
            }
        }
    }

    private func open(_ result: ArtworkUpgrade) async {
        loading = true
        defer { loading = false }
        do {
            let data = try await fetcher.search.imageData(result.candidate)
            guard !Task.isCancelled else { return }
            guard ArtworkImageFacts.inspect(data) == result.candidate.image else {
                message = "The provider’s image changed. Search again to review the latest match."
                return
            }
            selected = result
            preview = ArtworkPreview(candidate: result.candidate, data: data)
        } catch { message = "The full image couldn’t be loaded. Please try again." }
    }
}
