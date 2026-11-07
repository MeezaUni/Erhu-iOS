import SwiftUI

struct RadioStationView: View {
    let seed: RadioSeed
    @Environment(MixStore.self) private var mixes
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var plan: RadioPlan?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.md) {
                if let plan {
                    RadioHero(plan: plan)
                    if !plan.basedOn.isEmpty {
                        Text("Based on " + plan.basedOn.map(\.label).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.heroGutter)
                    }
                    HStack(spacing: Spacing.md) {
                        Button { actions.playRadio(plan) } label: {
                            Label("Play station", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .modifier(PaletteFilledButton())
                        Button { actions.playRadio(plan, shuffled: true) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.headline).controlSize(.large).buttonBorderShape(.capsule)
                    .padding(.horizontal, Spacing.heroGutter)
                    let ids = [plan.startSongId] + plan.songIds
                    let songs = Dictionary(library.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    ForEach(ids, id: \.self) { id in
                        if let song = songs[id] {
                            TrackRow(song: song, isCurrent: player.state.currentSong?.id == id,
                                     actions: router.songActions(actions)) { actions.playRadio(plan, startingAt: id) }
                        }
                    }
                } else if loaded {
                    EmptyState(message: "No available songs for this station. Add more music and reopen it.", systemImage: "dot.radiowaves.left.and.right")
                } else { ProgressView("Choosing tracks from your library…").padding() }
            }.padding(.bottom, Spacing.lg)
        }
        .tracksLibraryScrolling()
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .modifier(CollectionTopEdgeEffect())
        .background { CollectionPageBackground() }
        .collectionArtworkTheme(RadioHeroSelection.paletteSource(plan: plan, library: library.songs, artists: library.artists), alwaysFollowArtwork: true)
        .navigationTitle("Radio station").navigationBarTitleDisplayMode(.inline)
        .task(id: seed) {
            let next = await mixes.radio(seed)
            guard !Task.isCancelled else { return }
            plan = next; loaded = true
        }
    }
}

/// One shelf of album and radio destinations, interleaved rather than duplicated sections.
struct FeaturedSetlistsShelf: View {
    let includesRadio: Bool
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        let items = FeaturedSetlists.select(albums: library.featuredAlbums, covers: library.albumCoverSong,
            radioSongs: library.favorites + library.songs, includesRadio: includesRadio)
        if !items.isEmpty {
            Shelf(title: "Featured Setlists", lazy: false) {
                ForEach(items) { item in
                    switch item {
                    case .album(let album):
                        AlbumTile(album: album) { router.open(.album(album.id)) }.frame(width: ArtworkSize.shelf)
                    case .radio(let seed, let title, let subtitle, let cover):
                        radioTile(cover: cover, title: title, subtitle: subtitle, seed: seed)
                    }
                }
            }.padding(.bottom, Spacing.lg)
        }
    }

    private func radioTile(cover: Song, title: String, subtitle: String, seed: RadioSeed) -> some View {
        ArtworkTile(title: title + " Radio", subtitle: subtitle, action: { router.open(.radio(seed)) }) {
            RadioSetlistArtwork(cover: cover, title: title)
                .collectionArtworkTheme(.track(cover.url), alwaysFollowArtwork: true)
        }.frame(width: ArtworkSize.shelf)

    }
}

private struct RadioSetlistArtwork: View {
    let cover: Song
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Image(systemName: "waveform")
                Spacer()
                Text("RADIO").tracking(2).font(.caption2.bold())
            }
            SongArtworkView(song: cover, maxPixels: 350)
                .aspectRatio(1, contentMode: .fit).clipShape(Circle()).padding(.horizontal, 18)
            Text(title).font(.subheadline.bold()).lineLimit(1)
        }
        .padding(Spacing.md)
        .foregroundStyle(palette.onSurface)
        .background {
            ZStack { palette.surfaceVariant; palette.primary.opacity(0.15) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .ignore).accessibilityLabel(title + " Radio")
    }
}
