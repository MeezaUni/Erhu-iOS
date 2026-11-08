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
    @State private var confirmingApplyAll = false
    #if ERHU_ANIMATED_ART
    @Environment(AnimatedArtworkStore.self) private var motionArtwork
    #endif

    var body: some View {
        List {
            Section {
                Text("Find a larger version of your existing image. Review a match individually or apply all matching upgrades. Each replacement is checked again before saving. Saved images fit within \(TagWriter.maxArtworkPixels) pixels.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.applying {
                    ProgressView(value: Double(store.applied), total: Double(max(store.applyTotal, 1)))
                    Text("Applying \(store.applied) of \(store.applyTotal) upgrades").font(.caption)
                    Button("Stop after this image", role: .cancel) { store.cancel() }
                } else if store.scanning {
                    ProgressView(value: Double(store.checked), total: Double(max(store.total, 1)))
                    Text("Checked \(store.checked) of \(store.total)").font(.caption)
                    Button("Stop search", role: .cancel) { store.cancel() }
                } else {
                    Button(store.finished ? "Check for new upgrades" : store.checked > 0 ? "Continue checking for upgrades" : "Find higher-resolution matches") {
                        message = nil
                        store.scan(kind, library: library, search: fetcher.search)
                    }
                    .disabled(loading || saving)
                    if store.checked > 0 {
                        Button("Start a new search") {
                            message = nil
                            store.scan(kind, library: library, search: fetcher.search, restart: true)
                        }.disabled(loading || saving)
                    }
                    if store.finished {
                        Text("Checked \(store.checked). \(store.results.count) upgrade\(store.results.count == 1 ? "" : "s") to review. Some sources may have no matching larger image.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.skipped > 0 { Text("\(store.skipped) images or requests could not be checked.").font(.caption).foregroundStyle(.secondary) }
                }
                if let message { Text(message).font(.footnote) }
                if let message = store.message { Text(message).font(.footnote) }
                Text("Progress is saved after each image. Continue skips completed checks and includes new albums or artists.")
                    .font(.caption).foregroundStyle(.secondary)
            }.toolSectionAppearance()
            Section("Higher-resolution matches") {
                if !store.results.isEmpty {
                    Button {
                        if store.results.contains(where: hasDownloadedAnimation) { confirmingApplyAll = true }
                        else { store.applyAll(library: library, fetcher: fetcher) }
                    } label: {
                        Label("Apply to all (\(store.results.count))", systemImage: "checkmark.circle")
                    }
                    .disabled(store.scanning || store.applying || loading || saving)
                    .accessibilityIdentifier("artwork-upgrade-apply-all")
                }
                ForEach(store.results) { result in
                    Button { Task { await open(result) } } label: {
                        HStack(spacing: Spacing.md) {
                            currentImage(result.target)
                            VStack(alignment: .leading) {
                                Text(result.target.name).foregroundStyle(.primary)
                                Text("\(result.originalFacts.resolution) → \(result.candidate.image?.resolution ?? "larger")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if hasDownloadedAnimation(result) {
                                    Label("Animated cover downloaded", systemImage: "play.square.stack")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Likely same image · Review").font(.caption)
                            }
                        }
                    }.buttonStyle(.plain).disabled(loading || saving || store.applying || store.scanning)
                }
                if store.finished && store.results.isEmpty { Text("No larger same-image matches to review.").foregroundStyle(.secondary) }
            }.toolSectionAppearance()
        }
        .modifier(ToolPageAppearance())
        .navigationTitle(kind == .albums ? "Upgrade album covers" : "Upgrade artist photos")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView("Loading full image…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onDisappear { store.cancel() }
        .task { store.restore(kind, library: library) }
        .confirmationDialog("Apply all upgrades?", isPresented: $confirmingApplyAll, titleVisibility: .visible) {
            let animated = store.results.filter(hasDownloadedAnimation).count
            Button("Upgrade all \(store.results.count)") { store.applyAll(library: library, fetcher: fetcher) }
            Button("Upgrade \(store.results.count - animated), skip albums with animated covers") {
                store.applyAll(library: library, fetcher: fetcher, skipping: hasDownloadedAnimation)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let animated = store.results.filter(hasDownloadedAnimation).count
            Text("\(animated) of these albums already \(animated == 1 ? "has" : "have") a downloaded animated cover. Skipped albums stay in the list to review on their own.")
        }
        .sheet(item: $review) { item in
            ArtworkUpgradeReviewView(review: item, saving: saving, error: reviewError) {
                Task { await apply(item) }
            }
        }
    }

    /// The artwork in use now, beside its name.
    @ViewBuilder
    private func currentImage(_ target: ArtworkTarget) -> some View {
        switch target {
        case .album(let album):
            AlbumArtworkView(albumId: album.id, maxPixels: 144)
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        case .artist(let artist):
            ArtistArtworkView(artist: library.artist(artist.id) ?? artist, fontSize: 18, maxPixels: 144)
                .frame(width: 48, height: 48).clipShape(Circle())
        }
    }

    /// Whether the album already has an animated cover saved on this device.
    private func hasDownloadedAnimation(_ result: ArtworkUpgrade) -> Bool {
        #if ERHU_ANIMATED_ART
        if case .album(let album) = result.target { return motionArtwork.isDownloaded(album) }
        #endif
        return false
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
