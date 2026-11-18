import SwiftUI
import Observation

/// A server album or artist opened from search, with what is needed to show and reopen it.
struct RecentServerItem: Codable, Hashable, Sendable {
    let accountId: UUID
    let id: String
    let title: String
    let subtitle: String?
    let coverArt: String?
    /// The server's address and user, so the item still opens after the server is added again.
    var server = ""
    var username = ""
}

/// A recently opened search result.
enum RecentSearchItem: Identifiable, Equatable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case serverSong(StreamedSong)
    case serverAlbum(RecentServerItem)
    case serverArtist(RecentServerItem)

    var id: String { saved.key }

    /// What is kept between launches: library items by ID (looked up again, so a song that
    /// left the library drops out), server items whole.
    var saved: SavedRecentSearch {
        switch self {
        case .song(let song): .song(song.id)
        case .album(let album): .album(album.id)
        case .artist(let artist): .artist(artist.id)
        case .playlist(let playlist): .playlist(playlist.id)
        case .serverSong(let item): .serverSong(item)
        case .serverAlbum(let item): .serverAlbum(item)
        case .serverArtist(let item): .serverArtist(item)
        }
    }
}

enum SavedRecentSearch: Codable, Hashable, Sendable {
    case song(Int64), album(Int64), artist(Int64), playlist(Int64)
    case serverSong(StreamedSong), serverAlbum(RecentServerItem), serverArtist(RecentServerItem)

    var key: String {
        switch self {
        case .song(let id): "song:\(id)"
        case .album(let id): "album:\(id)"
        case .artist(let id): "artist:\(id)"
        case .playlist(let id): "playlist:\(id)"
        case .serverSong(let item): "server-song:\(item.server)/\(item.username)/\(item.song.id)"
        case .serverAlbum(let item): "server-album:\(item.server)/\(item.username)/\(item.id)"
        case .serverArtist(let item): "server-artist:\(item.server)/\(item.username)/\(item.id)"
        }
    }

    /// Keeps [item] first, drops any earlier copy, and caps the list.
    static func adding(_ item: SavedRecentSearch, to list: [SavedRecentSearch], limit: Int) -> [SavedRecentSearch] {
        Array(([item] + list.filter { $0.key != item.key }).prefix(limit))
    }
}

/// Library search (title / artist / album, accent- and case-insensitive) and its recent items.
@MainActor
@Observable
final class SearchStore {
    static let sectionLimit = 20
    private static let recentLimit = 15

    var query = "" {
        didSet { schedule() }
    }
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    /// Recent items, kept between launches.
    private var savedRecents: [SavedRecentSearch] = [] {
        didSet { recentStore.save(savedRecents) }
    }
    /// Matches on the connected music server (nil without one, or while it can't be reached).
    private(set) var server: ServerSearchResults?
    /// Searched as well as the library, when a server is connected (set by AppServices).
    @ObservationIgnored weak var servers: ServerStore?

    private let library: LibraryStore
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let recentStore = JSONStore<[SavedRecentSearch]>(name: "recent-searches.json")

    init(library: LibraryStore) {
        self.library = library
        savedRecents = recentStore.load() ?? []
    }

    /// Recent items as they are now: library items that left the library are skipped.
    var recents: [RecentSearchItem] {
        savedRecents.compactMap { saved in
            switch saved {
            case .song(let id): library.song(id).map(RecentSearchItem.song)
            case .album(let id): library.album(id).map(RecentSearchItem.album)
            case .artist(let id): library.artist(id).map(RecentSearchItem.artist)
            case .playlist(let id): library.playlist(id).map(RecentSearchItem.playlist)
            case .serverSong(let item): .serverSong(item)
            case .serverAlbum(let item): .serverAlbum(item)
            case .serverArtist(let item): .serverArtist(item)
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { await run() }
        }
    }

    func run() async {
        generation &+= 1
        let request = generation
        let text = query.trimmed
        let songs = library.songs, albums = library.albums, artists = library.artists
        let result = await Task.detached(priority: .userInitiated) {
            LibrarySearch.results(text, songs: songs, albums: albums, artists: artists)
        }.value
        guard !Task.isCancelled, request == generation, text == query.trimmed else { return }
        self.songs = result.songs; self.albums = result.albums; self.artists = result.artists
        await searchServer(text, request: request)
    }

    /// The same query on the connected server. Without a server, or when it can't be reached,
    /// search simply shows the library.
    private func searchServer(_ text: String, request: UInt64) async {
        guard !text.isEmpty, let servers, let account = servers.selected else {
            server = nil
            return
        }
        let limit = Self.sectionLimit
        if let index = servers.catalog(for: account.id) {
            // The server's catalog is on this device: matched like the library, at once.
            let found = await Task.detached(priority: .userInitiated) { index.search(text, limit: limit) }.value
            guard !Task.isCancelled, request == generation, text == query.trimmed else { return }
            server = found.artists.isEmpty && found.albums.isEmpty && found.songs.isEmpty ? nil
                : ServerSearchResults(account: account,
                                      artists: found.artists.map { RecentServerArtist(id: $0.id, name: $0.name, coverArt: $0.coverArt, albumCount: $0.albumCount) },
                                      albums: found.albums.map { RecentServerAlbum(id: $0.id, name: $0.name, artist: $0.artist, coverArt: $0.coverArt) },
                                      songs: found.songs)
            return
        }
        // No catalog yet (first use): ask the server.
        guard let client = servers.client(for: account.id) else { server = nil; return }
        let found = try? await client.search(text)
        guard !Task.isCancelled, request == generation, text == query.trimmed else { return }
        guard let found, !(found.artist.isEmpty && found.album.isEmpty && found.song.isEmpty) else { server = nil; return }
        server = ServerSearchResults(account: account,
                                     artists: found.artist.prefix(limit).map { RecentServerArtist(id: $0.id, name: $0.name, coverArt: $0.coverArt, albumCount: $0.albumCount) },
                                     albums: found.album.prefix(limit).map { RecentServerAlbum(id: $0.id, name: $0.name, artist: $0.artist, coverArt: $0.coverArt) },
                                     songs: Array(ServerCatalog.uniqueSongs(found.song.filter { $0.isVideo != true }).prefix(limit)))
    }

    func remember(_ item: RecentSearchItem) {
        savedRecents = SavedRecentSearch.adding(item.saved, to: savedRecents, limit: Self.recentLimit)
    }

    func forget(_ item: RecentSearchItem) { savedRecents.removeAll { $0.key == item.id } }

    func clearRecents() { savedRecents = [] }
}

/// What the connected server found for the search.
struct ServerSearchResults {
    let account: ServerAccount
    let artists: [RecentServerArtist]
    let albums: [RecentServerAlbum]
    let songs: [ServerSong]
}

struct RecentServerArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
}

struct RecentServerAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let coverArt: String?
}

/// Search over the library: artists, albums and songs as you type, recent items before you do.
struct SearchView: View {
    @Environment(SearchStore.self) private var search
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.query.trimmed.isEmpty {
                        recents
                    } else if search.songs.isEmpty && search.albums.isEmpty && search.artists.isEmpty && search.server == nil {
                        EmptyState(message: String(localized: "Nothing in your library matches \"\(search.query.trimmed)\"."), systemImage: "magnifyingglass")
                    } else {
                        results
                    }
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
            }
            .scrollDismissesKeyboard(.immediately)
            // What's playing stays in reach while searching; tapping it opens Now Playing.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let song = player.state.currentSong {
                    SearchNowPlayingBar(song: song) {
                        focused = false
                        router.showsSearch = false
                        router.showsNowPlaying = true
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.xs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                GlassSearchField(text: $search.query, prompt: "Songs, albums, artists", focused: $focused, close: { focused = false; router.showsSearch = false; dismiss() })
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.sm)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                focused = true
                servers.refreshCatalogs()
            }
            .task(id: library.songs) { await search.run() }
            // A server catalog arriving (or refreshed) updates the results at once.
            .task(id: servers.catalogVersion) { if !search.query.trimmed.isEmpty { await search.run() } }
            .modifier(ToolPageAppearance())
        }
    }

    /// Songs first, then albums, then artists; when the search is an artist's name, that
    /// artist comes first. The library's and the connected server's matches share each section,
    /// the library's first; something on both shows once, as the library's.
    @ViewBuilder private var results: some View {
        let server = search.server
        let account = server?.account
        // Songs the library has are already among its results.
        let remoteSongs = (server?.songs ?? []).filter { $0.isVideo != true && servers.librarySong(matching: $0) == nil }
        let remoteAlbums = (server?.albums ?? []).filter { servers.libraryAlbum(named: $0.name, artist: $0.artist ?? "") == nil }
        let remoteArtists = (server?.artists ?? []).filter { servers.libraryArtist(named: $0.name) == nil }
        let typed = SearchNormalizer.normalize(search.query)
        let artistFirst = search.artists.contains { SearchNormalizer.normalize($0.name) == typed }
            || remoteArtists.contains { SearchNormalizer.normalize($0.name) == typed }
        if artistFirst { artistSection(remoteArtists, account: account) }
        songSection(remoteSongs, account: account)
        albumSection(remoteAlbums, account: account)
        if !artistFirst { artistSection(remoteArtists, account: account) }
    }

    @ViewBuilder private func songSection(_ remoteSongs: [ServerSong], account: ServerAccount?) -> some View {
        if !search.songs.isEmpty || (account != nil && !remoteSongs.isEmpty) {
            SectionHeading(title: "Songs")
            let songActions = router.songActions(actions)
            ForEach(Array(search.songs.enumerated()), id: \.element.id) { index, song in
                TrackRow(song: song, isCurrent: song.id == player.state.currentSong?.id, actions: songActions) {
                    focused = false
                    search.remember(.song(song))
                    actions.play(search.songs, startIndex: index)
                }
            }
            if let account {
                let source = PlaybackSource.server(account: account.id, album: nil, title: account.name)
                let songs = servers.streamSongs(remoteSongs, account: account)
                let rowActions = servers.songActions(source: source)
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    TrackRow(song: song, isCurrent: song.id == player.state.currentSong?.id, actions: rowActions) {
                        focused = false
                        let remote = remoteSongs[index]
                        search.remember(.serverSong(StreamedSong(accountId: account.id, song: remote, playedAt: Date(),
                                                                 server: account.baseURL.absoluteString, username: account.username)))
                        servers.play([remote], account: account,
                                     source: .server(account: account.id, album: remote.albumId, title: remote.album ?? account.name))
                    }
                }
            }
        }
    }

    @ViewBuilder private func albumSection(_ remoteAlbums: [RecentServerAlbum], account: ServerAccount?) -> some View {
        if !search.albums.isEmpty || (account != nil && !remoteAlbums.isEmpty) {
            Shelf(title: "Albums") {
                ForEach(search.albums) { album in
                    AlbumTile(album: album) { open(.album(album)) }.frame(width: 128)
                }
                if let account {
                    ForEach(remoteAlbums) { album in
                        ServerTile(accountId: account.id, title: album.name, subtitle: album.artist, coverArt: album.coverArt,
                                   showsStreamBadge: true) {
                            search.remember(.serverAlbum(RecentServerItem(accountId: account.id, id: album.id, title: album.name,
                                                                          subtitle: album.artist, coverArt: album.coverArt,
                                                                          server: account.baseURL.absoluteString, username: account.username)))
                            openServer(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                        }
                        .frame(width: 128)
                    }
                }
            }
        }
    }

    @ViewBuilder private func artistSection(_ remoteArtists: [RecentServerArtist], account: ServerAccount?) -> some View {
        if !search.artists.isEmpty || (account != nil && !remoteArtists.isEmpty) {
            Shelf(title: "Artists") {
                ForEach(search.artists) { artist in
                    ArtistTile(artist: artist) { open(.artist(artist)) }.frame(width: 112)
                }
                if let account {
                    ForEach(remoteArtists) { artist in
                        ServerTile(accountId: account.id, title: artist.name, subtitle: artist.albumCount.map { countLabel($0, .album) },
                                   coverArt: artist.coverArt, placeholder: "music.mic", circular: true, showsStreamBadge: true) {
                            search.remember(.serverArtist(RecentServerItem(accountId: account.id, id: artist.id, title: artist.name,
                                                                           subtitle: nil, coverArt: artist.coverArt,
                                                                           server: account.baseURL.absoluteString, username: account.username)))
                            // One artist: their full page (albums, EPs, singles, tracks), like a
                            // library artist; a server entry naming several keeps its album list.
                            if ServerLibraryMerge.artistNames(artist.name, local: []).count == 1, servers.catalog(for: account.id) != nil {
                                openServer(.serverArtistNamed(ServerRef(accountId: account.id, id: ServerLibraryMerge.artistKey(artist.name), title: artist.name)))
                            } else {
                                openServer(.serverArtist(ServerRef(accountId: account.id, id: artist.id, title: artist.name)))
                            }
                        }
                        .frame(width: 112)
                    }
                }
            }
        }
    }

    private func openServer(_ route: Route) {
        dismiss()
        router.open(route)
    }

    @ViewBuilder private var recents: some View {
        if search.recents.isEmpty {
            EmptyState(message: "Search your songs, albums and artists.", systemImage: "magnifyingglass")
        } else {
            HStack {
                Text("Recent").font(.title3.weight(.bold))
                Spacer()
                Button("Clear") { search.clearRecents() }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.sm)
            ForEach(search.recents) { item in
                HStack(spacing: Spacing.md) {
                    Button { reopen(item) } label: { recentRow(item) }.buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { search.forget(item) } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary).frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from recent")
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            }
        }
    }

    private func recentRow(_ item: RecentSearchItem) -> some View {
        HStack(spacing: Spacing.md) {
            Group {
                switch item {
                case .song(let song): SongArtworkView(song: song, maxPixels: 144)
                case .album(let album): AlbumArtworkView(albumId: album.id, maxPixels: 144)
                case .artist(let artist): ArtistArtworkView(artist: artist, fontSize: 18)
                case .playlist(let playlist): PlaylistCoverView(playlist: playlist)
                case .serverSong(let item):
                    ServerCoverView(accountId: servers.account(for: item)?.id ?? item.accountId, coverArt: item.song.coverArt, maxPixels: 144)
                case .serverAlbum(let item):
                    ServerCoverView(accountId: serverAccount(item)?.id ?? item.accountId, coverArt: item.coverArt, maxPixels: 144, placeholder: "square.stack")
                case .serverArtist(let item):
                    ServerCoverView(accountId: serverAccount(item)?.id ?? item.accountId, coverArt: item.coverArt, maxPixels: 144, placeholder: "music.mic")
                }
            }
            .frame(width: ArtworkSize.list, height: ArtworkSize.list)
            .clipShape(itemShape(item))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(item)).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle(item)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: ArtworkSize.list)
        .contentShape(Rectangle())
    }

    private func itemShape(_ item: RecentSearchItem) -> AnyShape {
        switch item {
        case .artist, .serverArtist: return AnyShape(Circle())
        default: break
        }
        return AnyShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private func title(_ item: RecentSearchItem) -> String {
        switch item {
        case .song(let song): song.title
        case .album(let album): album.title
        case .artist(let artist): artist.name
        case .playlist(let playlist): playlist.name
        case .serverSong(let item): item.song.title
        case .serverAlbum(let item), .serverArtist(let item): item.title
        }
    }

    private func subtitle(_ item: RecentSearchItem) -> String {
        switch item {
        case .song(let song): "Song · \(song.artist)"
        case .album(let album): "Album · \(album.artist)"
        case .artist: "Artist"
        case .playlist(let playlist): "Playlist · \(countLabel(playlist.songCount, .song))"
        case .serverSong(let item): ["Song", item.song.artist, serverName(item.accountId, item.server, item.username)].compactMap { $0 }.joined(separator: " · ")
        case .serverAlbum(let item): ["Album", item.subtitle, serverName(item.accountId, item.server, item.username)].compactMap { $0 }.joined(separator: " · ")
        case .serverArtist(let item): "Artist · \(serverName(item.accountId, item.server, item.username))"
        }
    }

    /// The server a recent item came from, also after it was removed and added again.
    private func serverAccount(_ item: RecentServerItem) -> ServerAccount? {
        servers.account(item.accountId, server: item.server, username: item.username)
    }

    private func serverName(_ id: UUID, _ server: String, _ username: String) -> String {
        servers.account(id, server: server, username: username)?.name ?? String(localized: "Server not connected")
    }

    private func reopen(_ item: RecentSearchItem) {
        focused = false
        switch item {
        case .song(let song):
            search.remember(item)
            actions.play([song], startIndex: 0)
        case .serverSong(let recent):
            search.remember(item)
            guard let account = servers.account(for: recent) else {
                actions.show(String(localized: "Server not connected"))
                return
            }
            servers.play([recent.song], account: account,
                         source: .server(account: account.id, album: recent.song.albumId, title: recent.song.album ?? account.name))
        default:
            open(item)
        }
    }

    private func open(_ item: RecentSearchItem) {
        search.remember(item)
        dismiss()
        switch item {
        case .album(let album): router.open(.album(album.id))
        case .artist(let artist): router.open(.artist(artist.id))
        case .playlist(let playlist): router.open(.playlist(playlist.id))
        case .serverAlbum(let recent):
            router.open(.serverAlbum(ServerRef(accountId: serverAccount(recent)?.id ?? recent.accountId, id: recent.id, title: recent.title)))
        case .serverArtist(let recent):
            router.open(.serverArtist(ServerRef(accountId: serverAccount(recent)?.id ?? recent.accountId, id: recent.id, title: recent.title)))
        case .song, .serverSong: break
        }
    }
}

/// The song playing, at the bottom of Search: cover, title and play / pause. Tapping it opens Now Playing.
private struct SearchNowPlayingBar: View {
    let song: Song
    let onOpen: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    var body: some View {
        let state = player.state
        HStack(spacing: Spacing.md) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.md) {
                    SongArtworkView(song: song, maxPixels: 132)
                        .frame(width: ArtworkSize.miniPlayer, height: ArtworkSize.miniPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(1)
                        Text(player.isLoading ? String(localized: "Loading…") : song.artist)
                            .font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")
            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isLoading {
                        LoadingRing(fraction: StreamLoading.shared.fraction(of: song), size: 24)
                    } else {
                        Image(systemName: player.showsPause ? "pause.fill" : "play.fill").font(.title2)
                    }
                }
                .frame(width: 44, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.onSurface)
            .accessibilityLabel(player.isLoading ? "Loading, tap to stop" : (state.isPlaying ? "Pause" : "Play"))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs + 2)
        .frame(height: 60)
        .chromeSurface(enabled: settings.glassEnabled)
    }
}
