import SwiftUI
import Observation

/// A recently opened search result.
enum RecentSearchItem: Identifiable, Equatable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .song(let song): "song:\(song.id)"
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        case .playlist(let playlist): "playlist:\(playlist.id)"
        }
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
    private(set) var recents: [RecentSearchItem] = []
    /// Matches on the connected music server (nil without one, or while it can't be reached).
    private(set) var server: ServerSearchResults?
    /// Searched as well as the library, when a server is connected (set by AppServices).
    @ObservationIgnored weak var servers: ServerStore?

    private let library: LibraryStore
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(library: LibraryStore) { self.library = library }

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
        guard !text.isEmpty, let servers, let account = servers.selected, let client = servers.client(for: account.id) else {
            server = nil
            return
        }
        let found = try? await client.search(text)
        guard !Task.isCancelled, request == generation, text == query.trimmed else { return }
        guard let found, !(found.artist.isEmpty && found.album.isEmpty && found.song.isEmpty) else { server = nil; return }
        server = ServerSearchResults(account: account,
                                     artists: Array(found.artist.prefix(Self.sectionLimit)),
                                     albums: Array(found.album.prefix(Self.sectionLimit)),
                                     songs: Array(found.song.filter { $0.isVideo != true }.prefix(Self.sectionLimit)))
    }

    func remember(_ item: RecentSearchItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        recents = Array(recents.prefix(Self.recentLimit))
    }

    func forget(_ item: RecentSearchItem) { recents.removeAll { $0.id == item.id } }

    func clearRecents() { recents = [] }
}

/// What the connected server found for the search.
struct ServerSearchResults {
    let account: ServerAccount
    let artists: [ServerArtist]
    let albums: [ServerAlbum]
    let songs: [ServerSong]
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
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                GlassSearchField(text: $search.query, prompt: "Songs, albums, artists", focused: $focused, close: { focused = false; router.showsSearch = false; dismiss() })
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.sm)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { focused = true }
            .task(id: library.songs) { await search.run() }
            .modifier(ToolPageAppearance())
        }
    }

    @ViewBuilder private var results: some View {
        if !search.artists.isEmpty {
            Shelf(title: "Artists") {
                ForEach(search.artists) { artist in
                    ArtistTile(artist: artist) { open(.artist(artist)) }.frame(width: 112)
                }
            }
        }
        if !search.albums.isEmpty {
            Shelf(title: "Albums") {
                ForEach(search.albums) { album in
                    AlbumTile(album: album) { open(.album(album)) }.frame(width: 128)
                }
            }
        }
        if !search.songs.isEmpty {
            SectionHeading(title: "Songs")
            let songActions = router.songActions(actions)
            ForEach(Array(search.songs.enumerated()), id: \.element.id) { index, song in
                TrackRow(song: song, isCurrent: song.id == player.state.currentSong?.id, actions: songActions) {
                    search.remember(.song(song))
                    actions.play(search.songs, startIndex: index)
                }
            }
        }
        if let server = search.server { serverResults(server) }
    }

    /// The server's matches, after the library's, in the same shelves and rows.
    @ViewBuilder private func serverResults(_ server: ServerSearchResults) -> some View {
        let account = server.account
        if !server.artists.isEmpty {
            Shelf(title: String(localized: "Artists on \(account.name)")) {
                ForEach(server.artists) { artist in
                    ServerTile(accountId: account.id, title: artist.name, subtitle: artist.albumCount.map { countLabel($0, .album) },
                               coverArt: artist.coverArt, placeholder: "music.mic", circular: true) {
                        openServer(.serverArtist(ServerRef(accountId: account.id, id: artist.id, title: artist.name)))
                    }
                    .frame(width: 112)
                }
            }
        }
        if !server.albums.isEmpty {
            Shelf(title: String(localized: "Albums on \(account.name)")) {
                ForEach(server.albums) { album in
                    ServerTile(accountId: account.id, title: album.name, subtitle: album.artist, coverArt: album.coverArt) {
                        openServer(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                    }
                    .frame(width: 128)
                }
            }
        }
        if !server.songs.isEmpty {
            SectionHeading(title: String(localized: "Songs on \(account.name)"))
            let source = PlaybackSource.server(account: account.id, album: nil, title: account.name)
            let songs = servers.streamSongs(server.songs, account: account)
            let rowActions = servers.songActions(source: source)
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                TrackRow(song: song, isCurrent: song.id == player.state.currentSong?.id, actions: rowActions) {
                    let remote = server.songs[index]
                    servers.play([remote], account: account,
                                 source: .server(account: account.id, album: remote.albumId, title: remote.album ?? account.name))
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
        if case .artist = item { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private func title(_ item: RecentSearchItem) -> String {
        switch item {
        case .song(let song): song.title
        case .album(let album): album.title
        case .artist(let artist): artist.name
        case .playlist(let playlist): playlist.name
        }
    }

    private func subtitle(_ item: RecentSearchItem) -> String {
        switch item {
        case .song(let song): "Song · \(song.artist)"
        case .album(let album): "Album · \(album.artist)"
        case .artist: "Artist"
        case .playlist(let playlist): "Playlist · \(countLabel(playlist.songCount, .song))"
        }
    }

    private func reopen(_ item: RecentSearchItem) {
        switch item {
        case .song(let song):
            search.remember(item)
            actions.play([song], startIndex: 0)
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
        case .song: break
        }
    }
}
