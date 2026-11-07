import SwiftUI

struct ArtworkUpgradeView: View {
    let kind: ArtworkUpgradeKind
    @Environment(LibraryStore.self) private var library
    @Environment(ArtworkFetcherStore.self) private var fetcher
    @State private var store = ArtworkUpgradeStore()
    @State private var review: ArtworkUpgradeReview?
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var reviewError: String?

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
                    .disabled(loading || saving)
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
        .sheet(item: $review) { item in
            ArtworkUpgradeReviewView(review: item, saving: saving, error: reviewError) {
                Task { await apply(item) }
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
            guard let current = await ArtworkUpgradeStore.currentArtwork(result.target, library: library),
                  let comparison = ArtworkUpgradeReview(upgrade: result, original: current, replacement: data) else {
                message = "The current artwork or replacement changed. Search again to compare the latest images."
                return
            }
            reviewError = nil
            review = comparison
        } catch { message = "The full image couldn’t be loaded. Please try again." }
    }

    private func apply(_ item: ArtworkUpgradeReview) async {
        guard !saving else { return }
        saving = true
        reviewError = nil
        defer { saving = false }
        guard item.matchesCurrentArtwork(await ArtworkUpgradeStore.currentArtwork(item.upgrade.target, library: library)) else {
            reviewError = "Your current artwork changed after opening this comparison. Keep current, then search again."
            return
        }
        let success: Bool
        switch item.upgrade.target {
        case .album(let album): success = await fetcher.applyCover(item.upgrade.candidate, image: item.replacement, to: album)
        case .artist(let artist): success = await fetcher.applyPhoto(item.upgrade.candidate, image: item.replacement, to: artist)
        }
        if success { store.remove(item.upgrade); review = nil; message = "Higher-resolution artwork saved." }
        else { reviewError = "Couldn’t save the artwork. Try again." }
    }
}
