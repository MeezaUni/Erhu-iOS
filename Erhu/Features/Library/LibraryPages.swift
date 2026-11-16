import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: ArtworkSize.gridMin), spacing: Spacing.lg, alignment: .top)]

/// Albums as an artwork grid, with independent section search and a saved sort order.
struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(ServerStore.self) private var servers
    @AppStorage("library.albums.sort") private var sort = LibrarySort.title.rawValue
    @AppStorage("library.albums.source") private var source = LibrarySource.all.rawValue
    @State private var query = ""
    @State private var showsSearch = false
    /// The library's albums with the connected server's (marked as streamed), searched and sorted.
    @State private var results: [AlbumGridItem]?

    private struct Key: Hashable {
        let request: AlbumBrowseRequest
        let catalog: Int
        let account: UUID?
        let source: String
    }

    private var request: AlbumBrowseRequest {
        AlbumBrowseRequest(albums: library.albums, songs: library.songs, facts: library.browseFacts,
                           lastPlayed: library.albumLastPlayed, query: query, sort: LibrarySort(rawValue: sort) ?? .title)
    }

    var body: some View {
        LibraryBrowseScrollView(title: "Albums", isTabRoot: true, query: $query, showsSearch: $showsSearch) {
            LibrarySortMenu(selection: $sort, options: LibrarySort.albums)
            if servers.selected != nil { LibrarySourceMenu(selection: $source) }
        } content: {
            if library.albums.isEmpty && (results ?? []).isEmpty {
                EmptyState(message: library.isScanning ? "Scanning your music…" : "No albums yet.", systemImage: "square.stack")
            } else if let results {
                Text(countLabel(results.count, .album)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.gutter)
                if results.isEmpty {
                    EmptyState(message: "No albums match your search.", systemImage: "magnifyingglass")
                } else {
                    LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                        ForEach(results) { item in
                            switch item {
                            case .local(let album):
                                AlbumTile(album: album) { router.open(.album(album.id)) }
                            case .server(let account, let album):
                                ServerTile(accountId: account, title: album.name, subtitle: album.artist, coverArt: album.coverArt,
                                           showsStreamBadge: true) {
                                    router.open(.serverAlbum(ServerRef(accountId: account, id: album.id, title: album.name)))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, Spacing.sm)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .task(id: Key(request: request, catalog: servers.catalogVersion, account: servers.connectedAccount?.id, source: source)) {
            let snapshot = request
            let chosen = LibrarySource(rawValue: source) ?? .all
            // Albums only on the server show while it answers; the library's always show.
            let account = servers.connectedAccount?.id
            let index = account.flatMap { servers.catalog(for: $0) }
            // Typing cancels the previous delivery; large libraries never sort on the UI thread.
            if !snapshot.query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let updated = await Task.detached(priority: .userInitiated) { () -> [AlbumGridItem] in
                let query = snapshot.query.trimmingCharacters(in: .whitespaces)
                let server = index.map { query.isEmpty ? $0.catalog.albums : $0.search(query, limit: 500).albums } ?? []
                return ServerLibraryMerge.albums(local: snapshot.results(), server: server, accountId: account,
                                                 sort: snapshot.sort, searching: !query.isEmpty, source: chosen,
                                                 allLocal: snapshot.albums)
            }.value
            guard !Task.isCancelled else { return }
            results = updated
        }
        .refreshable { library.scan() }
    }
}

/// The Library landing page: Playlists, Favorites, Artists and Songs, each a short horizontal
/// preview with a "More" that opens the full shelf.
struct LibraryOverviewView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router

    private static let previewLimit = 15
    @State private var serverArtists: [NamedServerArtist] = []

    var body: some View {
        LibraryRootScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Shelf(title: LibraryShelf.playlists.label, onMore: { router.open(.shelf(.playlists)) }) {
                    NewPlaylistTile { router.showsNewPlaylist = true }.frame(width: 136)
                    ForEach(library.playlists.prefix(Self.previewLimit)) { playlist in
                        PlaylistTile(playlist: playlist) { router.open(.playlist(playlist.id)) }.frame(width: 136)
                    }
                }
                section(LibraryShelf.favorites.label, empty: library.favorites.isEmpty,
                        message: String(localized: "No favorites yet. Tap the heart on any song to add it here."), more: { router.open(.shelf(.favorites)) }) {
                    ForEach(Array(library.favorites.prefix(Self.previewLimit).enumerated()), id: \.element.id) { index, song in
                        SongTile(song: song) { actions.play(library.favorites, startIndex: index, source: .favorites) }.frame(width: 136)
                    }
                }
                section(LibraryShelf.artists.label, empty: library.artists.isEmpty,
                        message: String(localized: "No artists found. Pull down to rescan."), more: { router.open(.shelf(.artists)) }) {
                    ForEach(library.artists) { artist in
                        ArtistTile(artist: artist) { router.open(.artist(artist.id)) }.frame(width: 136)
                    }
                    ServerArtistTiles(artists: serverArtists, limit: Self.previewLimit, width: 136)
                }
                section("Songs", empty: library.songs.isEmpty,
                        message: library.isScanning ? "Scanning your music…" : String(localized: "No songs found. Pull down to rescan."), more: { router.open(.allSongs) }) {
                    ForEach(Array(library.songs.prefix(Self.previewLimit).enumerated()), id: \.element.id) { index, song in
                        SongTile(song: song) { actions.play(library.songs, startIndex: index) }.frame(width: 136)
                    }
                }
                ServerLibraryShelves()
            }
            .padding(.vertical, Spacing.sm)
        }
        .tracksLibraryScrolling()
        .refreshable { library.scan() }
        .loadsServerArtists($serverArtists)
    }

    @ViewBuilder
    private func section<Cards: View>(_ title: String, empty: Bool, message: String, more: @escaping () -> Void,
                                      @ViewBuilder cards: @escaping () -> Cards) -> some View {
        if empty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: title, onMore: more)
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.gutter)
            }
        } else {
            Shelf(title: title, onMore: more, content: cards)
        }
    }
}

/// A full Library shelf, opened from the overview's "More".
struct LibraryShelfView: View {
    let shelf: LibraryShelf
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    @State private var query = ""
    @State private var showsSearch = false
    @State private var serverArtists: [NamedServerArtist] = []

    var body: some View {
        LibraryBrowseScrollView(title: shelf.label, showsControls: false, query: $query, showsSearch: $showsSearch) {
            EmptyView()
        } content: {
            switch shelf {
            case .playlists:
                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    NewPlaylistTile { router.showsNewPlaylist = true }
                    ForEach(library.playlists.filter { query.isBlank || SearchNormalizer.matches($0.name, query) }) { playlist in
                        PlaylistTile(playlist: playlist) { router.open(.playlist(playlist.id)) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            case .favorites:
                SongList(songs: library.favorites.filter { query.isBlank || SearchNormalizer.matches($0.title + " " + $0.artist + " " + $0.album, query) }, emptyMessage: String(localized: "No favorites yet. Tap the heart on any song to add it here."),
                         emptyIcon: "heart", source: .favorites)
            case .artists:
                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    ForEach(library.artists.filter { query.isBlank || SearchNormalizer.matches($0.name, query) }) { artist in
                        ArtistTile(artist: artist) { router.open(.artist(artist.id)) }
                    }
                    ServerArtistTiles(artists: serverArtists, query: query)
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            }
        }
        .navigationTitle("")
        .loadsServerArtists($serverArtists)
    }
}

/// Every track, with a local query, remembered sorting, and tag-based genre/mood filters. While
/// a server answers, its songs the library lacks join the list, each marked as streamed.
struct AllSongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServerStore.self) private var servers
    @AppStorage("library.songs.sort") private var sort = LibrarySort.title.rawValue
    @AppStorage("library.songs.source") private var source = LibrarySource.all.rawValue
    /// The connected server's songs matching the search and genre (moods need the library's tags).
    @State private var serverSongs: [Song] = []
    @State private var query = ""
    @State private var showsSearch = false
    @State private var genre = ""
    @State private var mood = LibraryMood.all
    @State private var results: [Song]?
    @State private var genres: [String] = []

    private var request: SongBrowseRequest {
        SongBrowseRequest(songs: library.songs, facts: library.browseFacts, query: query,
                          sort: LibrarySort(rawValue: sort) ?? .title, genre: genre, mood: mood)
    }

    private var selectedSource: LibrarySource { LibrarySource(rawValue: source) ?? .all }

    /// The library's results and the server's in one list, as the Source filter asks.
    @State private var shown: [Song]?

    private func updateShown() {
        shown = results.map {
            ServerLibraryMerge.songList(local: $0, streamed: serverSongs, sort: LibrarySort(rawValue: sort) ?? .title,
                                        searching: !query.trimmingCharacters(in: .whitespaces).isEmpty, source: selectedSource)
        }
    }

    var body: some View {
        LibraryBrowseScrollView(title: "Songs", query: $query, showsSearch: $showsSearch) {
            LibrarySortMenu(selection: $sort, options: LibrarySort.songs)
            if servers.selected != nil { LibrarySourceMenu(selection: $source) }
            genreMenu
            Menu {
                Picker("Mood", selection: $mood) {
                    Text("All moods").tag(LibraryMood.all)
                    ForEach(LibraryMood.allCases.filter { $0 != .all }, id: \.rawValue) { Text($0.label).tag($0) }
                }
            } label: {
                BrowseControlLabel(title: mood.label, icon: "sparkles", selected: mood != .all)
            }
            if !genre.isEmpty || mood != .all {
                Button { genre = ""; mood = .all } label: { BrowseControlLabel(title: "Reset", icon: "xmark") }
                    .accessibilityLabel("Clear genre and mood filters")
            }
        } content: {
            if mood != .all {
                Text(mood == .throwback ? "Throwback uses your songs’ year tags: released \(Moods.throwbackYears) or more years ago."
                     : "Mood matches use your songs’ genre and tempo tags.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.gutter)
            }
            if let shown {
                Text(countLabel(shown.count, .song)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.gutter)
                SongList(songs: shown, emptyMessage: library.songs.isEmpty && serverSongs.isEmpty ? String(localized: "No songs found.") : String(localized: "No songs match. Try another search, genre, or mood. Songs need genre tags to match a mood."), emptyIcon: "music.note")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .navigationTitle("")
        .task(id: request) {
            let snapshot = request
            if !snapshot.query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let updated = await Task.detached(priority: .userInitiated) {
                (snapshot.results(), LibraryBrowse.genres(in: snapshot.songs))
            }.value
            guard !Task.isCancelled else { return }
            results = updated.0
            genres = updated.1
            updateShown()
        }
        .onChange(of: source) { updateShown() }
        .refreshable { library.scan() }
        .task(id: "\(query)|\(genre)|\(mood.rawValue)|\(servers.catalogVersion)|\(servers.connectedAccount?.id.uuidString ?? "")|\(library.songs.count)") {
            // Only while the server answers; moods need the library's tags.
            guard mood == .all, let account = servers.connectedAccount, let index = servers.catalog(for: account.id) else {
                if !serverSongs.isEmpty { serverSongs = []; updateShown() }
                return
            }
            let text = query, genre = genre, library = library.songs
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                ServerLibraryMerge.songs(in: index, query: text, genre: genre, excluding: ServerLibraryMerge.SongKeys(library))
            }.value
            guard !Task.isCancelled else { return }
            serverSongs = servers.streamSongs(found, account: account)
            updateShown()
        }
    }

    private var genreMenu: some View {
        Menu {
            Picker("Genre", selection: $genre) {
                Text("All genres").tag("")
                Text("Untagged").tag(LibraryBrowse.untaggedGenre)
                ForEach(genres, id: \.self) { Text($0).tag(SectionSearch.key($0)) }
            }
        } label: {
            BrowseControlLabel(title: genre.isEmpty ? "Genre" : genre == LibraryBrowse.untaggedGenre ? "Untagged" : genres.first { SectionSearch.key($0) == genre } ?? "Genre",
                               icon: "guitars", selected: !genre.isEmpty)
        }
    }
}

/// A plain list of tracks that plays from the tapped one.
struct SongList: View {
    let songs: [Song]
    var emptyMessage = ""
    var emptyIcon = "music.note"
    var origin: CollectionRef?
    var showTrackNumbers = false
    var source: PlaybackSource?
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        let songActions = router.songActions(actions, source: source ?? origin.map { PlaybackSource($0) })
        let currentId = player.state.currentSong?.id
        LazyVStack(spacing: 0) {
            if songs.isEmpty {
                EmptyState(message: emptyMessage, systemImage: emptyIcon)
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                TrackRow(song: song, isCurrent: song.id == currentId, showTrackNumber: showTrackNumbers, displayTrackNumber: showTrackNumbers ? index + 1 : nil, actions: songActions) {
                    actions.play(songs, startIndex: index, origin: origin, source: source)
                }
            }
        }
    }
}

/// The connected server's artists the library doesn't have, among the library's (each marked as
/// streamed), by name. Nothing while the server doesn't answer. [artists] comes from
/// [loadsServerArtists] on the page.
struct ServerArtistTiles: View {
    let artists: [NamedServerArtist]
    var query = ""
    var limit: Int?
    var width: CGFloat?
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router

    var body: some View {
        let shown = artists.filter { query.isBlank || SearchNormalizer.matches($0.name, query) }
        if let account = servers.connectedAccount {
            ForEach(limit.map { Array(shown.prefix($0)) } ?? shown) { artist in
                ServerTile(accountId: account.id, title: artist.name, subtitle: countLabel(artist.songIds.count, .song),
                           coverArt: artist.coverArt, placeholder: "person", circular: true, showsStreamBadge: true) {
                    router.open(.serverArtistNamed(ServerRef(accountId: account.id, id: artist.key, title: artist.name)))
                }
                .frame(width: width)
            }
        }
    }
}

private struct ServerArtistsLoader: ViewModifier {
    @Binding var artists: [NamedServerArtist]
    @Environment(ServerStore.self) private var servers
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content.task(id: "\(servers.catalogVersion)|\(servers.connectedAccount?.id.uuidString ?? "")|\(library.artists.count)") {
            let named = await servers.namedArtists()
            let local = servers.libraryArtistKeys
            artists = named.values.filter { !local.contains($0.key) && !$0.songIds.isEmpty }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

extension View {
    /// Loads the connected server's artists that the library doesn't have into [artists].
    func loadsServerArtists(_ artists: Binding<[NamedServerArtist]>) -> some View { modifier(ServerArtistsLoader(artists: artists)) }
}
