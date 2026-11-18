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
                    // The library's and, while connected, the server's songs in this station.
                    let songs = Dictionary(actions.songs(ids).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    ForEach(ids, id: \.self) { id in
                        if let song = songs[id] {
                            TrackRow(song: song, isCurrent: player.state.currentSong?.id == id,
                                     actions: router.songActions(actions)) { actions.playRadio(plan, startingAt: id) }
                        }
                    }
                    MoreRadioStations(plan: plan, seed: seed)
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

/// Home's radio stations: five of your top artists' stations, a new draw every few hours
/// ([RadioRotation]); before the library has any, the featured albums' and favourite songs'.
struct RadioStationShelf: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var slot = RadioRotation.slot(hours: RadioRotation.radioHours)

    var body: some View {
        let rotation = RadioRotation.stations(library.radioPool, slot: slot)
        Group {
            if !rotation.isEmpty {
                Shelf(title: "Featured Radio Stations", lazy: false) {
                    ForEach(rotation) { album in
                        RadioTile(album: album) { router.open(.radio(.album(album.id))) }
                            .frame(width: ArtworkSize.shelf)
                    }
                }.padding(.bottom, Spacing.lg)
            } else if !fallback.isEmpty {
                Shelf(title: "Featured Radio Stations", lazy: false) {
                    ForEach(fallback) { station in
                        ArtworkTile(title: station.title, subtitle: station.subtitle,
                                    action: { router.open(.radio(station.seed)) }) {
                            RadioStationTileArtwork(cover: station.cover, title: station.title)
                                .collectionArtworkTheme(.track(station.cover.url), alwaysFollowArtwork: true)
                        }.frame(width: ArtworkSize.shelf)
                    }
                }.padding(.bottom, Spacing.lg)
            }
        }
        .task(id: slot) {
            // The next draw arrives on its own when the window turns over.
            let wait = RadioRotation.nextChange(hours: RadioRotation.radioHours).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(wait, 1) + 1))
            guard !Task.isCancelled else { return }
            slot = RadioRotation.slot(hours: RadioRotation.radioHours)
        }
    }

    private struct Station: Identifiable {
        let seed: RadioSeed
        let title: String
        let subtitle: String
        let cover: Song
        var id: String { seed.key }
    }

    private var fallback: [Station] {
        let albums = library.featuredAlbums.prefix(3).compactMap { album -> Station? in
            guard let cover = library.albumCoverSong[album.id] else { return nil }
            return Station(seed: .album(album.id), title: album.title, subtitle: String(localized: "Album radio"), cover: cover)
        }
        let songs = (library.favorites.isEmpty ? Array(library.songs.prefix(3)) : Array(library.favorites.prefix(3))).map {
            Station(seed: .song($0.id), title: $0.title, subtitle: $0.artist + " · " + String(localized: "Song radio"), cover: $0)
        }
        return albums + songs
    }
}

/// A station's tile: the station page's cover (its lead artist in the middle, two more of the
/// station's artists behind on either side, over the lead's colours, under the RADIO badge),
/// "Artist Radio" and the album it is based on.
struct RadioTile: View {
    let album: Album
    let action: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(MixStore.self) private var mixes
    @State private var portraits: [Song] = []

    var body: some View {
        ArtworkTile(title: String(localized: "\(album.artist) Radio"), subtitle: String(localized: "Based on \(album.title)"), action: action) {
            Group {
                if portraits.isEmpty, let cover = library.albumCoverSong[album.id] {
                    RadioStationTileArtwork(cover: cover, title: album.artist)
                        .collectionArtworkTheme(.track(cover.url), alwaysFollowArtwork: true)
                } else {
                    RadioCover(portraits: portraits)
                }
            }
        }
        .task(id: "\(album.id)|\(library.songs.count)") {
            let signature = library.songs.count
            guard let plan = await mixes.stationCover(album.id, librarySignature: signature), !Task.isCancelled else { return }
            portraits = RadioHeroSelection.songs(plan: plan, library: library.songs)
        }
    }
}

/// The station page's cover at tile size.
private struct RadioCover: View {
    let portraits: [Song]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let source: ArtworkPaletteSource = portraits.first.map { lead -> ArtworkPaletteSource in
            if let path = library.artist(lead.artistId)?.artworkPath?.nonBlank {
                return .image(URL(fileURLWithPath: LibraryPaths.resolveImage(path)))
            }
            return .track(lead.url)
        } ?? .track(nil)
        RadioCoverLayout(portraits: portraits)
            .collectionArtworkTheme(source, alwaysFollowArtwork: true)
    }
}

private struct RadioCoverLayout: View {
    let portraits: [Song]
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                LinearGradient(colors: [palette.primary.opacity(0.45), palette.background], startPoint: .top, endPoint: .bottom)
                ForEach(Array(portraits.dropFirst().prefix(2).enumerated()), id: \.offset) { index, song in
                    portrait(song)
                        .frame(width: side * 0.44, height: side * 0.44)
                        .position(x: index == 0 ? side * 0.10 : side * 0.90, y: side * 0.58)
                }
                if let lead = portraits.first {
                    portrait(lead)
                        .frame(width: side * 0.62, height: side * 0.62)
                        .position(x: side * 0.5, y: side * 0.58)
                }
                VStack {
                    HStack {
                        Image(systemName: "waveform")
                        Spacer()
                        Text("RADIO").tracking(1.4).font(.system(size: 10, weight: .bold))
                    }
                    .font(.caption)
                    .foregroundStyle(palette.onSurface)
                    .padding(Spacing.sm)
                    Spacer()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .accessibilityHidden(true)
    }

    private func portrait(_ song: Song) -> some View {
        FileImageView(path: library.artist(song.artistId)?.artworkPath, maxPixels: 300) {
            SongArtworkView(song: song, maxPixels: 300)
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(palette.outline.opacity(0.5), lineWidth: 1.5) }
    }
}

/// Stations to try next from the one on screen (Android's "More stations").
struct MoreRadioStations: View {
    let plan: RadioPlan
    let seed: RadioSeed
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        let recommended = recommendations()
        if !recommended.isEmpty {
            Shelf(title: "More stations", lazy: false) {
                ForEach(recommended) { album in
                    RadioTile(album: album) { router.open(.radio(.album(album.id))) }
                        .frame(width: ArtworkSize.shelf)
                }
            }
            .padding(.top, Spacing.lg)
        }
    }

    private func recommendations() -> [Album] {
        let current: Album?
        if case .album(let id) = seed { current = library.album(id) }
        else { current = library.song(plan.startSongId).flatMap { library.album($0.albumId) } }
        guard let current else { return [] }
        var seen = Set<Int64>()
        let artists = ([plan.startSongId] + plan.songIds).compactMap { library.song($0)?.artistId }.filter { seen.insert($0).inserted }
        return RadioRotation.recommendations(library.radioPool, current: current, stationArtistIds: artists,
                                             slot: RadioRotation.slot(hours: RadioRotation.radioHours))
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
