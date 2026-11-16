import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: ArtworkSize.gridMin), spacing: Spacing.lg, alignment: .top)]

/// Albums as an artwork grid, with independent section search and a saved sort order.
struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(ServerStore.self) private var servers
    @AppStorage("library.albums.sort") private var sort = LibrarySort.title.rawValue
    @State private var query = ""
    @State private var showsSearch = false
    /// The library's albums with the connected server's (marked as streamed), searched and sorted.
    @State private var results: [AlbumGridItem]?

    private struct Key: Hashable {
        let request: AlbumBrowseRequest
        let catalog: Int
        let account: UUID?
    }

    private var request: AlbumBrowseRequest {
        AlbumBrowseRequest(albums: library.albums, songs: library.songs, facts: library.browseFacts,
                           lastPlayed: library.albumLastPlayed, query: query, sort: LibrarySort(rawValue: sort) ?? .title)
    }

    var body: some View {
        LibraryBrowseScrollView(title: "Albums", isTabRoot: true, query: $query, showsSearch: $showsSearch) {
            LibrarySortMenu(selection: $sort, options: LibrarySort.albums)
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
        .task(id: Key(request: request, catalog: servers.catalogVersion, account: servers.selected?.id)) {
            let snapshot = request
            let account = servers.selected?.id
            let index = account.flatMap { servers.catalog(for: $0) }
            // Typing cancels the previous delivery; large libraries never sort on the UI thread.
            if !snapshot.query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let updated = await Task.detached(priority: .userInitiated) { () -> [AlbumGridItem] in
                let query = snapshot.query.trimmingCharacters(in: .whitespaces)
                let server = index.map { query.isEmpty ? $0.catalog.albums : $0.search(query, limit: 500).albums } ?? []
                return ServerLibraryMerge.albums(local: snapshot.results(), server: server, accountId: account,
                                                 sort: snapshot.sort, searching: !query.isEmpty)
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
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            }
        }
        .navigationTitle("")
    }
}

/// Every track, with a local query, remembered sorting, and tag-based genre/mood filters.
struct AllSongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServerStore.self) private var servers
    @Environment(PlayerController.self) private var player
    @AppStorage("library.songs.sort") private var sort = LibrarySort.title.rawValue
    /// The connected server's songs matching the search and genre (moods need the library's tags).
    @State private var serverSongs: [ServerSong] = []
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

    var body: some View {
        LibraryBrowseScrollView(title: "Songs", query: $query, showsSearch: $showsSearch) {
            LibrarySortMenu(selection: $sort, options: LibrarySort.songs)
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
            if let results {
                Text(countLabel(results.count + serverSongs.count, .song)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.gutter)
                if !(results.isEmpty && !serverSongs.isEmpty) {
                    SongList(songs: results, emptyMessage: library.songs.isEmpty ? String(localized: "No songs found.") : String(localized: "No songs match. Try another search, genre, or mood. Songs need genre tags to match a mood."), emptyIcon: "music.note")
                }
                if let account = servers.selected, !serverSongs.isEmpty {
                    serverSection(account)
                }
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
        }
        .refreshable { library.scan() }
        .task(id: "\(query)|\(genre)|\(mood.rawValue)|\(servers.catalogVersion)|\(servers.selected?.id.uuidString ?? "")") {
            guard mood == .all, let account = servers.selected, let index = servers.catalog(for: account.id) else {
                serverSongs = []
                return
            }
            let text = query, genre = genre
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { ServerLibraryMerge.songs(in: index, query: text, genre: genre) }.value
            guard !Task.isCancelled else { return }
            serverSongs = found
        }
    }

    /// The server's songs, streamed (each row marked), after the library's.
    @ViewBuilder private func serverSection(_ account: ServerAccount) -> some View {
        SectionHeading(title: String(localized: "Songs on \(account.name)"))
        let source = PlaybackSource.server(account: account.id, album: nil, title: account.name)
        let rowActions = servers.songActions(source: source)
        LazyVStack(spacing: 0) {
            ForEach(Array(serverSongs.enumerated()), id: \.offset) { index, remote in
                let song = servers.streamSongs([remote], account: account).first
                if let song {
                    TrackRow(song: song, isCurrent: song.id == player.state.currentSong?.id, actions: rowActions) {
                        // This song and the next ones (a bounded queue, not the whole server).
                        let upcoming = Array(serverSongs[index...].prefix(100))
                        servers.play(upcoming, account: account,
                                     source: .server(account: account.id, album: remote.albumId, title: remote.album ?? account.name))
                    }
                }
            }
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
