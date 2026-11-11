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
                        Text(String(localized: "Based on \(plan.basedOn.map(\.label).formatted(.list(type: .and)))")).font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.heroGutter)
                    }
                    HStack(spacing: Spacing.md) {
                        Button { actions.playRadio(plan) } label: {
                            Label("Play station", systemImage: "play.fill").lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
                        }
                        .modifier(PaletteFilledButton())
                        Button { actions.playRadio(plan, shuffled: true) } label: {
                            Label("Shuffle", systemImage: "shuffle").lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
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

/// Featured stations have their own shelf, above the separate featured album shelf.
struct RadioStationShelf: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    private struct Station: Identifiable {
        let seed: RadioSeed
        let title: String
        let subtitle: String
        let cover: Song
        var id: String { seed.key }
    }
    private var stations: [Station] {
        let albums = library.featuredAlbums.prefix(3).compactMap { album -> Station? in
            guard let cover = library.albumCoverSong[album.id] else { return nil }
            return Station(seed: .album(album.id), title: album.title, subtitle: String(localized: "Album radio"), cover: cover)
        }
        let songs = (library.favorites.isEmpty ? Array(library.songs.prefix(3)) : Array(library.favorites.prefix(3))).map {
            Station(seed: .song($0.id), title: $0.title, subtitle: $0.artist + " · " + String(localized: "Song radio"), cover: $0)
        }
        return albums + songs
    }
    var body: some View {
        if !stations.isEmpty {
            Shelf(title: "Featured Radio Stations", lazy: false) {
                ForEach(stations) { station in
                    ArtworkTile(title: station.title, subtitle: station.subtitle,
                                action: { router.open(.radio(station.seed)) }) {
                        RadioStationTileArtwork(cover: station.cover, title: station.title)
                            .collectionArtworkTheme(.track(station.cover.url), alwaysFollowArtwork: true)
                    }.frame(width: ArtworkSize.shelf)
                }
            }.padding(.bottom, Spacing.lg)
        }
    }
}

private struct RadioStationTileArtwork: View {
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
