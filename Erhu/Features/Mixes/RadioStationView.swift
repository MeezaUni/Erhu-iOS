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
        let albumStations = library.featuredAlbums.prefix(3).compactMap { album -> Station? in
            guard let song = library.albumCoverSong[album.id] else { return nil }
            return Station(seed: .album(album.id), title: album.title, subtitle: "Album radio", cover: song)
        }
        let songStations = (library.favorites.isEmpty ? Array(library.songs.prefix(3)) : Array(library.favorites.prefix(3))).map {
            Station(seed: .song($0.id), title: $0.title, subtitle: "\($0.artist) · Song radio", cover: $0)
        }
        return albumStations + songStations
    }
    var body: some View {
        if !stations.isEmpty {
            Shelf(title: "Featured Radio Stations") {
                ForEach(stations) { station in
                    Button { router.open(.radio(station.seed)) } label: {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            SongArtworkView(song: station.cover, maxPixels: 350)
                                .frame(width: ArtworkSize.shelf, height: ArtworkSize.shelf)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                            Text(station.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(station.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(width: ArtworkSize.shelf, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, Spacing.lg)
        }
    }
}
