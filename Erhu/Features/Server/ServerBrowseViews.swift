import SwiftUI

/// A server cover, loaded with the account's credentials.
struct ServerCover: View {
    let account: ServerAccount
    let coverArt: String?
    var size: CGFloat = ArtworkSize.compact
    var symbol = "music.note"
    @Environment(ServerStore.self) private var servers

    var body: some View {
        let url = coverArt.flatMap { id in servers.client(for: account.id)?.coverArtURL(id, size: Int(size * 3)) }
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// An album row (cover, title, artist and year) that opens the album.
private struct ServerAlbumRow: View {
    let account: ServerAccount
    let album: ServerAlbum

    var body: some View {
        NavigationLink { ServerAlbumView(account: account, albumId: album.id, title: album.name) } label: {
            HStack(spacing: Spacing.md) {
                ServerCover(account: account, coverArt: album.coverArt, symbol: "square.stack")
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).lineLimit(1)
                    Text([album.artist, album.year.flatMap { $0 > 0 ? String($0) : nil }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Albums from getAlbumList2 ([type]: alphabeticalByName, newest, random…), loading more on scroll.
struct ServerAlbumListView: View {
    let account: ServerAccount
    let type: String
    let title: String
    @Environment(ServerStore.self) private var servers
    @State private var albums: [ServerAlbum] = []
    @State private var finished = false
    @State private var error: String?
    @State private var loading = false
    private let pageSize = 60

    var body: some View {
        List {
            ForEach(albums) { album in
                ServerAlbumRow(account: account, album: album)
                    .onAppear { if album.id == albums.last?.id { Task { await loadMore() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { Task { await loadMore() } }
                }
            } else if finished && albums.isEmpty {
                Text("No albums on this server yet.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .task { if albums.isEmpty { await loadMore() } }
        .refreshable {
            albums = []
            finished = false
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loading, !finished, let client = servers.client(for: account.id) else { return }
        loading = true
        defer { loading = false }
        do {
            // Random lists have no stable order to page through: one page is enough.
            let page = try await client.albumList(type, size: pageSize, offset: type == "random" ? 0 : albums.count)
            let known = Set(albums.map(\.id))
            albums += page.filter { !known.contains($0.id) }
            finished = page.count < pageSize || type == "random"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ServerArtistsView: View {
    let account: ServerAccount
    @Environment(ServerStore.self) private var servers
    @State private var filter = ""

    var body: some View {
        ServerContent(load: { try await requireClient(servers, account).artists() }) { artists in
            let shown = filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            List(shown) { artist in
                NavigationLink { ServerArtistView(account: account, artist: artist) } label: {
                    HStack(spacing: Spacing.md) {
                        ServerCover(account: account, coverArt: artist.coverArt, symbol: "music.mic")
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).lineLimit(1)
                            if let count = artist.albumCount { Text(countLabel(count, .album)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .searchable(text: $filter)
        }
        .navigationTitle("Artists")
    }
}

struct ServerArtistView: View {
    let account: ServerAccount
    let artist: ServerArtist
    @Environment(ServerStore.self) private var servers

    var body: some View {
        ServerContent(load: { try await requireClient(servers, account).artist(artist.id) }) { detail in
            List(detail.album) { album in ServerAlbumRow(account: account, album: album) }
        }
        .navigationTitle(artist.name)
    }
}

struct ServerAlbumView: View {
    let account: ServerAccount
    let albumId: String
    let title: String
    @Environment(ServerStore.self) private var servers

    var body: some View {
        ServerContent(load: { try await requireClient(servers, account).album(albumId) }) { album in
            ServerSongList(account: account, songs: album.song, showTrackNumbers: true) {
                VStack(spacing: Spacing.md) {
                    ServerCover(account: account, coverArt: album.coverArt, size: 220, symbol: "square.stack")
                    VStack(spacing: 2) {
                        Text(album.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text([album.artist, album.year.flatMap { $0 > 0 ? String($0) : nil }].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ServerPlaylistsView: View {
    let account: ServerAccount
    @Environment(ServerStore.self) private var servers

    var body: some View {
        ServerContent(load: { try await requireClient(servers, account).playlists() }) { playlists in
            List {
                if playlists.isEmpty { Text("No playlists on this server yet.").foregroundStyle(.secondary) }
                ForEach(playlists) { playlist in
                    NavigationLink { ServerPlaylistView(account: account, playlist: playlist) } label: {
                        HStack(spacing: Spacing.md) {
                            ServerCover(account: account, coverArt: playlist.coverArt, symbol: "music.note.list")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1)
                                if let count = playlist.songCount { Text(countLabel(count, .song)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
    }
}

struct ServerPlaylistView: View {
    let account: ServerAccount
    let playlist: ServerPlaylist
    @Environment(ServerStore.self) private var servers

    var body: some View {
        ServerContent(load: { try await requireClient(servers, account).playlist(playlist.id) }) { detail in
            ServerSongList(account: account, songs: detail.entry) {
                Text(playlist.name).font(.title3.weight(.semibold)).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ServerSearchView: View {
    let account: ServerAccount
    @Environment(ServerStore.self) private var servers
    @State private var query = ""
    @State private var result: SubsonicSearchResult?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            if let result {
                if result.artist.isEmpty && result.album.isEmpty && result.song.isEmpty {
                    Text("Nothing found on the server.").foregroundStyle(.secondary)
                }
                if !result.artist.isEmpty {
                    Section("Artists") {
                        ForEach(result.artist) { artist in
                            NavigationLink(artist.name) { ServerArtistView(account: account, artist: artist) }
                        }
                    }
                }
                if !result.album.isEmpty {
                    Section("Albums") { ForEach(result.album) { ServerAlbumRow(account: account, album: $0) } }
                }
                if !result.song.isEmpty {
                    Section("Songs") {
                        ForEach(Array(result.song.enumerated()), id: \.element.id) { index, song in
                            ServerSongRow(account: account, songs: result.song, index: index, showTrackNumber: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, albums and songs")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { result = nil; error = nil; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let client = servers.client(for: account.id) else { return }
            do {
                result = try await client.search(text)
                error = nil
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Songs of an album or playlist with Play, Shuffle and Download for all, and per-song actions.
struct ServerSongList<Header: View>: View {
    let account: ServerAccount
    let songs: [ServerSong]
    var showTrackNumbers = false
    @ViewBuilder let header: () -> Header
    @Environment(ServerStore.self) private var servers

    var body: some View {
        List {
            Section {
                header()
                HStack(spacing: Spacing.md) {
                    Button { servers.play(songs, account: account) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { servers.play(songs, shuffled: true, account: account) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .disabled(songs.isEmpty)
                Button { servers.download(songs, account: account) } label: {
                    Label(songs.allSatisfy { servers.isDownloaded($0) } ? LocalizedStringKey("Downloaded") : LocalizedStringKey("Download to this device"),
                          systemImage: "arrow.down.circle")
                }
                .disabled(songs.isEmpty || songs.allSatisfy { servers.isDownloaded($0) })
            }
            .listRowSeparator(.hidden)
            Section {
                if songs.isEmpty { Text("No songs.").foregroundStyle(.secondary) }
                ForEach(Array(songs.enumerated()), id: \.offset) { index, _ in
                    ServerSongRow(account: account, songs: songs, index: index, showTrackNumber: showTrackNumbers)
                }
            }
        }
    }
}

/// One song: tap to stream from it; the menu has Play next, Add to queue and Download.
struct ServerSongRow: View {
    let account: ServerAccount
    let songs: [ServerSong]
    let index: Int
    var showTrackNumber = false
    @Environment(ServerStore.self) private var servers

    var body: some View {
        let song = songs[index]
        HStack(spacing: Spacing.md) {
            Button { servers.play(songs, startAt: index, account: account) } label: {
                HStack(spacing: Spacing.md) {
                    if showTrackNumber {
                        Text(song.track.map { String($0) } ?? "–").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 24)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).foregroundStyle(.primary).lineLimit(1)
                        Text([song.artist, song.duration.map { formatDuration(Int64($0) * 1000) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if servers.isDownloaded(song) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("On this device")
            }
            Menu {
                Button { servers.playNext(song, account: account) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { servers.addToQueue(song, account: account) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
                Button { servers.download([song], account: account) } label: { Label("Download to this device", systemImage: "arrow.down.circle") }
                    .disabled(servers.isDownloaded(song))
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(song.title)")
        }
    }
}

/// The account's client, or the error explaining why there is none.
@MainActor
func requireClient(_ servers: ServerStore, _ account: ServerAccount) throws -> SubsonicClient {
    guard let client = servers.client(for: account.id) else { throw SubsonicError.missingPassword }
    return client
}
