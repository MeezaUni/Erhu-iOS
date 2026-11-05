import PhotosUI
import SwiftUI
import UIKit

/// The Artwork Fetcher tool: albums without a cover and artists without a photo, each opening a
/// picker of what was found online (or a photo from the library).
struct ArtworkFetcherView: View {
    @Environment(ArtworkFetcherStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var tab = 0
    @State private var target: ArtworkTarget?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text("Albums (\(store.albums.count))").tag(0)
                    Text("Artists (\(store.artists.count))").tag(1)
                }
                .pickerStyle(.segmented)
                NavigationLink {
                    ArtworkUpgradeView(kind: tab == 0 ? .albums : .artists)
                } label: {
                    Label("Find same image in higher resolution", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                if store.isScanning {
                    HStack { ProgressView(); Text("Looking for missing artwork…") }
                }
                if let message = store.message {
                    Text(message).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                }
            } footer: {
                Text(tab == 0
                    ? "Albums whose songs carry no cover. A cover you pick is saved into every song of the album."
                    : "Artist photos are matched automatically when music is added. Retry missing photos here, or choose an artist to replace their image.")
            }.toolSectionAppearance()
            if tab == 0 {
                Section {
                    if store.albums.isEmpty && !store.isScanning {
                        Text("Every album has a cover.").foregroundStyle(palette.onSurfaceVariant)
                    }
                    ForEach(store.albums) { album in
                        Button { target = .album(album) } label: {
                            TargetRow(title: album.title, subtitle: album.artist, status: store.albumStatus[album.id]) {
                                AlbumArtworkView(albumId: album.id, maxPixels: 120)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }.toolSectionAppearance()
            } else {
                Section {
                    Button {
                        Task { await store.autoMatchArtists() }
                    } label: {
                        HStack {
                            Label("Match photos automatically", systemImage: "sparkles")
                            if store.isAutoMatching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.isAutoMatching || !store.artists.contains(where: { $0.artworkPath == nil }))
                    ForEach(store.artists) { artist in
                        Button { target = .artist(artist) } label: {
                            TargetRow(title: artist.name, subtitle: countLabel(artist.songCount, "song"), status: store.artistStatus[artist.id]) {
                                ArtistArtworkView(artist: artist, fontSize: 18)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }.toolSectionAppearance()
            }
        }.modifier(ToolPageAppearance())
        .navigationTitle("Artwork Fetcher")
        .toolbar {
            Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Find missing artwork")
                .disabled(store.isScanning)
        }
        .task { if store.albums.isEmpty && store.artists.isEmpty { await store.scan() } }
        .sheet(item: $target) { ArtworkPickerSheet(target: $0) }
    }
}

private struct TargetRow<Art: View>: View {
    let title: String
    let subtitle: String
    let status: ArtworkStatus?
    @ViewBuilder let art: () -> Art
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.md) {
            art().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                if let status { Text(status.label).font(.caption2).foregroundStyle(palette.onSurfaceVariant).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.onSurfaceVariant)
        }
        .contentShape(Rectangle())
    }
}

/// What artwork is being chosen for.
enum ArtworkTarget: Identifiable, Sendable {
    case album(Album)
    case artist(Artist)

    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        }
    }

    var name: String {
        switch self {
        case .album(let album): album.title
        case .artist(let artist): artist.name
        }
    }
}

/// Search never writes tags. Every online/custom image gets a full preview and explicit Apply.
struct ArtworkPickerSheet: View {
    let target: ArtworkTarget
    @Environment(ArtworkFetcherStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ArtworkCandidate] = []
    @State private var loading = true
    @State private var saving = false
    @State private var photo: PhotosPickerItem?
    @State private var saveError: String?
    @State private var preview: ArtworkPreview?
    @State private var preparingPreview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    Link(destination: webSearchURL) { Label("Search images in browser", systemImage: "magnifyingglass") }
                    Text("Web results have their own usage rights. Choose a permitted image and import it from Photos.")
                        .font(.caption).foregroundStyle(.secondary)
                    if loading {
                        HStack { ProgressView(); Text("Searching iTunes, MusicBrainz, Deezer and Wikimedia…") }.font(.footnote)
                    } else if candidates.isEmpty {
                        Text("Nothing found online.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.sm)], spacing: Spacing.sm) {
                        ForEach(candidates) { candidate in
                            ArtworkCandidateTile(candidate: candidate) { Task { await preparePreview(candidate) } }
                        }
                    }
                }
                .padding(Spacing.lg)
            }
            .disabled(saving || preparingPreview)
            .overlay { if saving || preparingPreview { ProgressView(saving ? "Saving…" : "Loading preview…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Couldn’t save artwork", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
            .sheet(item: $preview) { item in
                ArtworkPreviewView(preview: item, saving: saving) {
                    Task {
                        if let candidate = item.candidate { await apply(candidate, image: item.data) }
                        else { await apply(item.data) }
                        preview = nil
                    }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            saveError = "The selected photo could not be loaded."
                            return
                        }
                        guard ArtworkImageFacts.thumbnail(data, maxPixels: 32) != nil else {
                            saveError = "The selected photo could not be decoded."
                            return
                        }
                        preview = ArtworkPreview(candidate: nil, data: data)
                    } catch { saveError = error.localizedDescription }
                    photo = nil
                }
            }
        }
    }

    private func load() async {
        switch target {
        case .album(let album): candidates = await store.albumCovers(album)
        case .artist(let artist): candidates = await store.artistPhotos(artist)
        }
        loading = false
    }

    private var failureReason: String {
        let status: ArtworkStatus?
        switch target {
        case .album(let album): status = store.albumStatus[album.id]
        case .artist(let artist): status = store.artistStatus[artist.id]
        }
        if case .failed(let reason)? = status { return reason }
        return "The image could not be saved. Try another image."
    }

    private var webSearchURL: URL {
        let query: String
        switch target {
        case .album(let album): query = [album.title, album.artist, "album cover image"].joined(separator: " ")
        case .artist(let artist): query = artist.name + " artist photo"
        }
        return requestURL("https://www.google.com/search", [("q", query), ("tbm", "isch")])
    }

    private func preparePreview(_ candidate: ArtworkCandidate) async {
        guard !preparingPreview, !saving else { return }
        preparingPreview = true
        defer { preparingPreview = false }
        do {
            let bytes = try await store.search.imageData(candidate)
            guard !Task.isCancelled else { return }
            var checked = candidate
            checked.image = ArtworkImageFacts.inspect(bytes)
            preview = ArtworkPreview(candidate: checked, data: bytes)
        } catch { saveError = "The full image could not be verified. Try another image." }
    }

    private func apply(_ candidate: ArtworkCandidate, image: Data) async {
        guard !saving else { return }
        saving = true
        let saved: Bool
        switch target {
        case .album(let album): saved = await store.applyCover(candidate, image: image, to: album)
        case .artist(let artist): saved = await store.applyPhoto(candidate, image: image, to: artist)
        }
        saving = false
        if saved { dismiss() } else { saveError = failureReason }
    }

    private func apply(_ image: Data) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        switch target {
        case .album(let album):
            if await store.applyCover(image, to: album) { dismiss() } else { saveError = failureReason }
        case .artist(let artist):
            do {
                try store.storePhoto(image, for: artist, source: "CUSTOM")
                dismiss()
            } catch { saveError = error.localizedDescription }
        }
    }
}

private struct ArtworkCandidateTile: View {
    let candidate: ArtworkCandidate
    let choose: () -> Void
    @Environment(ArtworkFetcherStore.self) private var store
    @State private var thumbnail: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                        else { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                    Text(candidate.source).font(.caption2).foregroundStyle(.secondary)
                    if let match = candidate.match {
                        Text(match.album).font(.caption).lineLimit(2)
                        Text(match.artist + (match.year > 0 ? " · \(match.year)" : "")).font(.caption2).lineLimit(2)
                        Text(candidate.recommended ? "Recommended" : match.review.joined(separator: " · ").ifBlank("Preview to confirm"))
                            .font(.caption2).foregroundStyle(candidate.recommended ? Color.green : Color.secondary)
                    }
                    if let image = candidate.image { Text(image.resolution).font(.caption2).foregroundStyle(.secondary) }
                }
            }.buttonStyle(.plain).accessibilityLabel("Preview image from \(candidate.source)")
            if let credit = candidate.credit {
                Text(credit.author).font(.caption2).lineLimit(2)
                Link(credit.license + " · source", destination: credit.page).font(.caption2)
            }
        }
        .task(id: candidate.url) {
            guard let bytes = try? await store.search.imageData(candidate), !Task.isCancelled,
                  let cg = ArtworkImageFacts.thumbnail(bytes, maxPixels: 350) else { return }
            thumbnail = UIImage(cgImage: cg)
        }
    }
}

struct ArtworkPreview: Identifiable {
    let id = UUID()
    let candidate: ArtworkCandidate?
    let data: Data
}

struct ArtworkPreviewView: View {
    let preview: ArtworkPreview
    let saving: Bool
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image = ArtworkImageFacts.thumbnail(preview.data, maxPixels: 1600) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    }
                    if let match = preview.candidate?.match {
                        Text(match.album).font(.headline)
                        Text(match.artist + (match.year > 0 ? " · \(match.year)" : ""))
                        if !match.review.isEmpty { Text(match.review.joined(separator: " · ")).foregroundStyle(.secondary) }
                    }
                    if let facts = ArtworkImageFacts.inspect(preview.data) { Text(facts.resolution).font(.caption) }
                    if let candidate = preview.candidate { Text(candidate.source).font(.caption) }
                    if let credit = preview.candidate?.credit {
                        Text(credit.author + " · " + credit.license).font(.caption)
                        Link("Image source", destination: credit.page)
                    }
                    Text("Check the complete image and edition. Apply saves this image to your selected album or artist.").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Preview artwork").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Apply", action: apply).disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
