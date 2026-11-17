import SwiftUI
import UIKit

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
    /// Marks it as streamed, where it sits among the library's own music.
    var showsStreamBadge = false
    let action: () -> Void

    @Environment(ServerStore.self) private var servers

    var body: some View {
        // The page it opens shows the large cover: get it ready as the page slides in.
        ArtworkTile(title: title, subtitle: subtitle, circular: circular, action: {
            ServerCovers.prepareLarge(accountId: accountId, coverArt: coverArt, servers: servers)
            action()
        }) {
            ServerCoverView(accountId: accountId, coverArt: coverArt, placeholder: placeholder)
                .overlay(alignment: .topTrailing) {
                    if showsStreamBadge { StreamBadge().padding(6) }
                }
        }
    }
}

/// A server album, laid out as a library album: cover, facts, Play / Shuffle and numbered tracks.
struct ServerAlbumPage: View {
    let ref: ServerRef
    @Environment(ServerStore.self) private var servers

    var body: some View {
        if let account = servers.account(ref.accountId) {
            ServerContent(cached: servers.cachedAlbum(ref.id, account: account.id),
                          load: { try await servers.album(ref.id, account: account) }) { album in
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
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @State private var coverRevision = 0

    var body: some View {
        let tracks = ServerCatalog.uniqueSongs(remote.filter { $0.isVideo != true })
        // Read so the page redraws when the library changes (a song saved or deleted).
        let _ = library.songs.count
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
                if !servers.isReachable(account.id) {
                    Label(String(localized: "\(account.name) isn't connected right now. Its songs play again once it's back."),
                          systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.gutter).padding(.bottom, Spacing.sm)
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
        // A server that was off may be back: check as the page opens.
        .task { if !servers.isReachable(account.id) { servers.chooseRoutes() } }
        // On Wi-Fi, start fetching the first song as the page opens, so Play starts at once.
        .task(id: songs.first?.path) {
            guard !player.isStreamingDirectly, let first = songs.first else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, player.state.currentSong?.path != first.path else { return }
            // Connected and its start loaded (on mobile data too: a few seconds of audio)...
            player.prepareToStream(first)
            for song in songs.prefix(3) { ServerStream.shared.prefetchHead(song) }
            // ...and on Wi-Fi fetched whole, so it plays on the full player.
            if !servers.networkIsExpensive { ServerStream.shared.prefetch([first]) }
        }
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
            ServerContent(cached: servers.cachedArtist(ref.id, account: account.id),
                          load: { try await servers.artist(ref.id, account: account) }) { artist in
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

/// A server artist by name: Play / Shuffle, their albums, then every song crediting them
/// (their own and features), from the saved catalog.
struct NamedServerArtistPage: View {
    let ref: ServerRef
    @Environment(ServerStore.self) private var servers
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player
    @State private var artist: NamedServerArtist?
    @State private var loaded = false

    var body: some View {
        if let account = servers.account(ref.accountId), let index = servers.catalog(for: account.id) {
            let albums = (artist?.albumIds ?? []).compactMap { index.albumEntry($0) }
                .sorted { ($0.year ?? 0) == ($1.year ?? 0) ? $0.name < $1.name : ($0.year ?? 0) > ($1.year ?? 0) }
            let remote = index.songs(artist?.songIds ?? [])
            // Read so the page redraws when the library changes: a song saved to or deleted from
            // the phone switches between the library's copy and the streamed one.
            let _ = library.songs.count
            let songs = servers.streamSongs(remote, account: account)
            let source = PlaybackSource.server(account: account.id, album: nil, title: ref.title)
            let rowActions = servers.songActions(source: source)
            let currentId = player.state.currentSong?.id
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CollectionHeroHeader(title: ref.title, subtitle: nil,
                                         facts: "\(countLabel(songs.count, .song)) · \(countLabel(albums.count, .album))",
                                         canPlay: !songs.isEmpty,
                                         onPlay: { servers.play(remote, shuffled: false, account: account, source: source) },
                                         onShuffle: { servers.play(remote, shuffled: true, account: account, source: source) }) {
                        ServerCoverView(accountId: account.id, coverArt: artist?.coverArt, maxPixels: 1200, placeholder: "person")
                    }
                    // Like a library artist: albums, EPs and singles by their number of songs.
                    albumRow("Albums", albums.filter { index.songCount(ofAlbum: $0.id) >= 7 }, account: account)
                    albumRow("EPs", albums.filter { (3...6).contains(index.songCount(ofAlbum: $0.id)) }, account: account)
                    albumRow(String(localized: "Singles"), albums.filter { (1...2).contains(index.songCount(ofAlbum: $0.id)) }, account: account)
                    if !songs.isEmpty {
                        SectionHeading(title: "Tracks")
                        ForEach(Array(songs.enumerated()), id: \.offset) { position, song in
                            TrackRow(song: song, isCurrent: song.id == currentId, actions: rowActions) {
                                servers.play(remote, startAt: position, account: account, source: source)
                            }
                        }
                    } else if loaded {
                        EmptyState(message: String(localized: "No songs."))
                    }
                }
            }
            .tracksLibraryScrolling()
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .modifier(CollectionTopEdgeEffect())
            .navigationBarTitleDisplayMode(.inline)
            .background { CollectionPageBackground() }
            .task(id: servers.catalogVersion) {
                artist = await servers.namedArtists()[ref.id]
                loaded = true
            }
        } else {
            ServerNotConnectedView()
        }
    }

    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [ServerCatalog.Album], account: ServerAccount) -> some View {
        if !albums.isEmpty {
            Shelf(title: title) {
                ForEach(albums, id: \.id) { album in
                    ServerTile(accountId: account.id, title: album.name,
                               subtitle: album.year.flatMap { $0 > 0 ? String($0) : nil } ?? album.artist,
                               coverArt: album.coverArt, showsStreamBadge: true) {
                        router.open(.serverAlbum(ServerRef(accountId: account.id, id: album.id, title: album.name)))
                    }
                    .frame(width: 128)
                }
            }
            .padding(.bottom, Spacing.sm)
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

/// On Home, under Recently played albums: the last five albums streamed from a server, with
/// covers saved on this device. They stay listed without a connection; opening one then explains
/// that its server isn't connected.
struct RecentlyStreamedShelf: View {
    @Environment(ServerStore.self) private var servers
    @Environment(AppRouter.self) private var router
    @State private var notConnected = false

    var body: some View {
        let albums = servers.recentAlbums
        if !albums.isEmpty {
            Shelf(title: String(localized: "Recently streamed albums")) {
                ForEach(albums) { album in
                    ArtworkTile(title: album.title, subtitle: album.artist) { open(album) } cover: {
                        StreamedAlbumCover(album: album)
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

    private func open(_ album: StreamedAlbum) {
        guard let account = servers.account(album.accountId, server: album.server, username: album.username) else {
            notConnected = true
            return
        }
        if let albumId = album.albumId {
            router.open(.serverAlbum(ServerRef(accountId: account.id, id: albumId, title: album.title)))
        } else if !servers.playRecent(album) {
            notConnected = true
        }
    }
}

/// A Recently streamed album's cover, from the copy saved on this device (fetched once if missing).
private struct StreamedAlbumCover: View {
    let album: StreamedAlbum
    @Environment(ServerStore.self) private var servers
    @Environment(\.palette) private var palette
    @State private var image: UIImage?
    @State private var revision = 0

    var body: some View {
        let file = album.coverFile
        ZStack {
            if let image {
                FillImage(image: image)
            } else {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: "square.stack").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerCovers.didChange)) { note in
            if note.object as? String == file.path { revision += 1 }
        }
        .task(id: "\(file.path)|\(revision)") {
            if FileManager.default.fileExists(atPath: file.path) {
                image = await ArtworkLoader.shared.image(atPath: file.path, maxPixels: 400)
            } else {
                servers.saveCover(of: album)
            }
        }
        .accessibilityHidden(true)
    }
}
