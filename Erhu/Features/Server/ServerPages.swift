import SwiftUI

/// An album, artist or playlist on a music server, as a navigation destination.
struct ServerRef: Hashable, Sendable {
    let accountId: UUID
    let id: String
    let title: String
}

/// The account's client, or the error explaining why there is none.
@MainActor
func requireClient(_ servers: ServerStore, _ account: ServerAccount) throws -> SubsonicClient {
    guard let client = servers.client(for: account.id) else { throw SubsonicError.missingPassword }
    return client
}

/// Shown where a server page was opened for a server that is no longer connected.
struct ServerNotConnectedView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: Spacing.md) {
            EmptyState(message: String(localized: "This music is on a server that is no longer connected in Erhu. Add the server again in Music Server to play it."),
                       systemImage: "wifi.slash")
            Button("Music Server") { router.open(.tool(.musicServer)) }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Server not connected")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An album or playlist cover with its title, as the library's own cards.
struct ServerTile: View {
    let accountId: UUID
    let title: String
    let subtitle: String?
    let coverArt: String?
    var placeholder = "square.stack"
    var circular = false
    let action: () -> Void

    var body: some View {
        ArtworkTile(title: title, subtitle: subtitle, circular: circular, action: action) {
            ServerCoverView(accountId: accountId, coverArt: coverArt, placeholder: placeholder)
        }
    }
}

/// A server album, laid out as a library album: cover, facts, Play / Shuffle and numbered tracks.
struct ServerAlbumPage: View {
    let ref: ServerRef
    @Environment(ServerStore.self) private var servers

    var body: some View {
        if let account = servers.account(ref.accountId) {
            ServerContent(load: { try await requireClient(servers, account).album(ref.id) }) { album in
                ServerCollectionPage(account: account, title: album.name, subtitle: album.artist, year: album.year,
                                     coverArt: album.coverArt, remote: album.song, numbered: true,
                                     source: .server(account: account.id, album: album.id, title: album.name))
            }
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ServerNotConnectedView()
        }
    }
}

/// A server playlist, laid out as a library playlist.
struct ServerPlaylistPage: View {
    let ref: ServerRef
    @Environment(ServerStore.self) private var servers

    var body: some View {
        if let account = servers.account(ref.accountId) {
            ServerContent(load: { try await requireClient(servers, account).playlist(ref.id) }) { playlist in
                ServerCollectionPage(account: account, title: playlist.name, subtitle: nil, year: nil,
                                     coverArt: playlist.coverArt, remote: playlist.entry, numbered: false,
                                     source: .server(account: account.id, album: nil, title: playlist.name))
            }
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ServerNotConnectedView()
        }
    }
}

/// The shared album / playlist page for server music.
private struct ServerCollectionPage: View {
    let account: ServerAccount
    let title: String
    let subtitle: String?
    let year: Int?
    let coverArt: String?
    let remote: [ServerSong]
    let numbered: Bool
    let source: PlaybackSource
    @Environment(ServerStore.self) private var servers
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @State private var coverRevision = 0

    var body: some View {
        let tracks = remote.filter { $0.isVideo != true }
        let songs = servers.streamSongs(tracks, account: account)
        let songActions = servers.songActions(source: source)
        let currentId = player.state.currentSong?.id
        let coverFile = coverArt.map { ServerCovers.fileURL(accountId: account.id, coverArt: $0) }
        let allSaved = !tracks.isEmpty && tracks.allSatisfy { servers.isDownloaded($0) }
        // Read on every refresh, so the page's colours follow the cover once it has arrived.
        let themeCover = coverRevision >= 0 ? coverFile.flatMap { ServerCovers.hasCover(at: $0) ? $0 : nil } : nil
        ScrollView {
            LazyVStack(spacing: 0) {
                CollectionHeroHeader(title: title, subtitle: subtitle, facts: collectionFacts(year: year, songs: songs),
                                     canPlay: !songs.isEmpty,
                                     onPlay: { servers.play(tracks, shuffled: false, account: account, source: source) },
                                     onShuffle: { servers.play(tracks, shuffled: true, account: account, source: source) }) {
                    ServerCoverView(accountId: account.id, coverArt: coverArt, maxPixels: 1200, placeholder: "square.stack")
                }
                if songs.isEmpty { EmptyState(message: String(localized: "No songs.")) }
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    TrackRow(song: song, isCurrent: song.id == currentId, showTrackNumber: numbered,
                             displayTrackNumber: index + 1, actions: songActions) {
                        servers.play(tracks, startAt: index, account: account, source: source)
                    }
                }
            }
        }
        .tracksLibraryScrolling()
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .modifier(CollectionTopEdgeEffect())
        .toolbar {
            Menu {
                Button { songs.reversed().forEach { actions.playNext($0, source: source) } } label: {
                    Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { songs.forEach { actions.addToQueue($0, source: source) } } label: { Label("Add to queue", systemImage: "text.badge.plus") }
                Button { servers.download(tracks, account: account) } label: {
                    Label(allSaved ? LocalizedStringKey("Downloaded") : LocalizedStringKey("Download to this device"), systemImage: "arrow.down.circle")
                }
                .disabled(tracks.isEmpty || allSaved)
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Album options")
        }
        .background { CollectionPageBackground() }
        .collectionArtworkTheme(.image(themeCover))
        .onReceive(NotificationCenter.default.publisher(for: ServerCovers.didChange)) { note in
            if note.object as? String == coverFile?.path { coverRevision += 1 }
        }
    }
}

private let serverGridColumns = [GridItem(.adaptive(minimum: ArtworkSize.gridMin), spacing: Spacing.lg, alignment: .top)]

/// A server artist: their albums as the library's album grid.
struct ServerArtistPage: View {
    let ref: ServerRef
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let account = servers.account(ref.accountId) {
            ServerContent(load: { try await requireClient(servers, account).artist(ref.id) }) { artist in
                ScrollView {
                    if artist.album.isEmpty { EmptyState(message: String(localized: "No albums on this server yet."), systemImage: "square.stack") }
                    LazyVGrid(columns: serverGridColumns, spacing: Spacing.xl) {
                        ForEach(artist.album) { album in
                            ServerTile(accountId: account.id, title: album.name, subtitle: album.year.flatMap { $0 > 0 ? String($0) : nil } ?? album.artist,
                                       coverArt: album.coverArt) {
                                router.open(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, Spacing.sm)
                }
                .tracksLibraryScrolling()
            }
            .navigationTitle(ref.title)
        } else {
            ServerNotConnectedView()
        }
    }
}

/// Every album on a server, by name, as the library's album grid; more load as you scroll.
struct ServerAlbumsPage: View {
    let accountId: UUID
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router
    @State private var albums: [ServerAlbum] = []
    @State private var finished = false
    @State private var loading = false
    @State private var error: String?
    private let pageSize = 60

    var body: some View {
        if let account = servers.account(accountId) {
            ScrollView {
                LazyVGrid(columns: serverGridColumns, spacing: Spacing.xl) {
                    ForEach(albums) { album in
                        ServerTile(accountId: account.id, title: album.name, subtitle: album.artist, coverArt: album.coverArt) {
                            router.open(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                        }
                        .onAppear { if album.id == albums.last?.id { Task { await loadMore(account) } } }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
                if loading { ProgressView().padding() }
                if let error {
                    VStack(spacing: Spacing.sm) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadMore(account) } }.buttonStyle(.bordered)
                    }
                    .padding()
                } else if finished && albums.isEmpty {
                    EmptyState(message: String(localized: "No albums on this server yet."), systemImage: "square.stack")
                }
            }
            .tracksLibraryScrolling()
            .navigationTitle(String(localized: "Albums on \(account.name)"))
            .task { if albums.isEmpty { await loadMore(account) } }
            .refreshable {
                albums = []
                finished = false
                await loadMore(account)
            }
        } else {
            ServerNotConnectedView()
        }
    }

    private func loadMore(_ account: ServerAccount) async {
        guard !loading, !finished, let client = servers.client(for: account.id) else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.albumList("alphabeticalByName", size: pageSize, offset: albums.count)
            let known = Set(albums.map(\.id))
            albums += page.filter { !known.contains($0.id) }
            finished = page.count < pageSize
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// On the Library page: the connected server's newest albums and its playlists, as shelves.
/// Nothing is shown without a server, or while it can't be reached.
struct ServerLibraryShelves: View {
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router
    @State private var albums: [ServerAlbum] = []
    @State private var playlists: [ServerPlaylist] = []
    @State private var loadedFor: UUID?

    var body: some View {
        let account = servers.selected
        Group {
            if let account, loadedFor == account.id {
                if !albums.isEmpty {
                    Shelf(title: String(localized: "Albums on \(account.name)"), onMore: { router.open(.serverAlbums(account.id)) }) {
                        ForEach(albums) { album in
                            ServerTile(accountId: account.id, title: album.name, subtitle: album.artist, coverArt: album.coverArt) {
                                router.open(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                            }
                            .frame(width: 136)
                        }
                    }
                }
                if !playlists.isEmpty {
                    Shelf(title: String(localized: "Playlists on \(account.name)")) {
                        ForEach(playlists) { playlist in
                            ServerTile(accountId: account.id, title: playlist.name, subtitle: playlist.songCount.map { countLabel($0, .song) },
                                       coverArt: playlist.coverArt, placeholder: "music.note.list") {
                                router.open(.serverPlaylist(ServerRef(accountId: account.id, id: playlist.id, title: playlist.name)))
                            }
                            .frame(width: 136)
                        }
                    }
                }
            }
        }
        .task(id: account?.id) {
            guard let account, let client = servers.client(for: account.id) else { loadedFor = nil; return }
            async let newest = try? client.albumList("newest", size: 15)
            async let lists = try? client.playlists()
            let (foundAlbums, foundLists) = await (newest, lists)
            guard !Task.isCancelled else { return }
            albums = foundAlbums ?? []
            playlists = foundLists ?? []
            loadedFor = account.id
        }
    }
}

/// On Home, under Recently played albums: the last albums streamed from a server. They stay
/// listed without a connection; opening one then explains that its server isn't connected.
struct RecentlyStreamedShelf: View {
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router
    @State private var notConnected = false

    var body: some View {
        let albums = servers.recentAlbums
        if !albums.isEmpty {
            Shelf(title: String(localized: "Recently streamed albums")) {
                ForEach(albums) { album in
                    // A server added again has a new ID: covers and pages follow the current one.
                    ServerTile(accountId: servers.account(for: album.item)?.id ?? album.accountId,
                               title: album.title, subtitle: album.artist, coverArt: album.coverArt) {
                        if let account = servers.account(for: album.item) {
                            router.open(.serverAlbum(ServerRef(accountId: account.id, id: album.albumId, title: album.title)))
                        } else {
                            notConnected = true
                        }
                    }
                    .frame(width: ArtworkSize.shelf)
                }
            }
            .padding(.bottom, Spacing.lg)
            .alert("Server not connected", isPresented: $notConnected) {
                Button("Music Server") { router.open(.tool(.musicServer)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This album was streamed from a server that is no longer connected in Erhu. Add the server again in Music Server to play it.")
            }
        }
    }
}
