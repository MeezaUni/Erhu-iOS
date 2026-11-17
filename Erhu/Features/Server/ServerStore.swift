import Foundation
import Network
import Observation

/// The listener's music servers (Erhu Server or another Subsonic-compatible server), the chosen
/// one, streaming quality, and songs being downloaded to this device.
@MainActor
@Observable
final class ServerStore {
    private(set) var accounts: [ServerAccount] = []
    var selectedId: UUID? {
        didSet { UserDefaults.standard.set(selectedId?.uuidString, forKey: Keys.selected) }
    }
    var quality: StreamQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Keys.quality) }
    }
    /// Downloads in this session, newest last.
    private(set) var downloads: [ServerDownload] = []
    /// Songs streamed lately, newest first (kept between launches; only what is needed to play them again).
    private(set) var recentlyStreamed: [StreamedSong] = []
    /// Home's Recently streamed albums: the last [albumLimit], newest first, each with its cover
    /// saved on this device, so they show with or without a connection.
    private(set) var recentAlbums: [StreamedAlbum] = []
    /// Favourite changes made in this session, by "account/song", shown before the server list is reloaded.
    private(set) var favouriteChanges: [String: Bool] = [:]
    /// A pairing link (QR code from the Erhu Server app) waiting to be shown as a filled-in Add server sheet.
    var pendingInvite: ServerInvite?
    /// Servers reached through their away-from-home address right now.
    private(set) var usingAway: Set<UUID> = []
    /// Servers that answered the last check.
    private(set) var reachable: Set<UUID> = []
    /// Whether each server converts songs to MP3 (checked once per session; see [quality]).
    private(set) var convertsToMP3: [UUID: Bool] = [:]
    /// Changes whenever a server's catalog (for search) is loaded or refreshed.
    private(set) var catalogVersion = 0
    @ObservationIgnored private var catalogs: [UUID: ServerCatalogIndex] = [:]
    @ObservationIgnored private var catalogTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private var clients: [UUID: SubsonicClient] = [:]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    /// Asked to check again while a check runs: it runs once more right after.
    @ObservationIgnored private var routeCheckAgain = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// On mobile data or Low Data Mode: nothing is fetched ahead of time just in case.
    @ObservationIgnored private(set) var networkIsExpensive = false
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let actions: LibraryActions
    @ObservationIgnored private let player: PlayerController

    private enum Keys {
        static let accounts = "musicServer.accounts"
        static let selected = "musicServer.selected"
        static let quality = "musicServer.streamQuality"
        static let recent = "musicServer.recentlyStreamed"
        static let recentAlbums = "musicServer.recentAlbums"
    }
    nonisolated static let albumLimit = 5
    static let recentLimit = 100

    init(library: LibraryStore, actions: LibraryActions, player: PlayerController) {
        self.library = library
        self.actions = actions
        self.player = player
        quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: Keys.quality) ?? "") ?? .automatic
        if let data = UserDefaults.standard.data(forKey: Keys.accounts),
           let saved = try? JSONDecoder().decode([ServerAccount].self, from: data) {
            accounts = saved
        }
        selectedId = UserDefaults.standard.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:)) ?? accounts.first?.id
        if let id = selectedId, !accounts.contains(where: { $0.id == id }) { selectedId = accounts.first?.id }
        if let data = UserDefaults.standard.data(forKey: Keys.recent),
           let saved = try? JSONDecoder().decode([StreamedSong].self, from: data) {
            recentlyStreamed = saved
        }
        if let data = UserDefaults.standard.data(forKey: Keys.recentAlbums),
           let saved = try? JSONDecoder().decode([StreamedAlbum].self, from: data) {
            recentAlbums = saved
        } else {
            // First launch with this list: start it from the songs streamed so far.
            for item in recentlyStreamed.reversed() {
                if let album = StreamedAlbum(item) { recentAlbums = Self.addingAlbum(album, to: recentAlbums).list }
            }
        }
        ServerStream.shared.clientProvider = { [weak self] id in self?.client(for: id) }
        ServerStream.shared.onStarted = { [weak self] accountId, song in self?.noteStreamed(song, accountId: accountId) }
        ServerStream.shared.trimCache()
        ServerStream.shared.allowsCaching = { [weak self] in !(self?.networkIsExpensive ?? false) }
        actions.streamFavorite = { [weak self] song in self?.toggleFavourite(stream: song) }
        ServerStream.shared.libraryAlbum = { [weak self] remote in self?.libraryAlbum(of: remote) }
        // A song that couldn't load because its server is off: its music leaves the library's
        // pages until the server answers again (checked when the app returns or the network changes).
        ServerStream.shared.onServerUnreachable = { [weak self] id in self?.reachable.remove(id) }
        ServerStream.shared.onServerReachable = { [weak self] id in
            guard let self else { return }
            self.reachable.insert(id)
            // Answering but no catalog yet (it failed or was never fetched): get it now.
            if self.catalogs[id] == nil { self.refreshCatalogs() }
        }
        ServerStream.shared.albumCoverArt = { [weak self] id, remote in
            remote.albumId.flatMap { self?.catalogs[id]?.albumEntry($0)?.coverArt }
        }
        // Songs streamed before a server was removed and added again belong to it again.
        for account in accounts { adoptRecents(of: account) }
        // Joining or leaving a Wi-Fi network decides between the home and away addresses.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in
                self?.networkIsExpensive = expensive
                self?.chooseRoutes()
                self?.checkConversions()
                self?.refreshCatalogs()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "erhu.server.path"))
    }

    var selected: ServerAccount? { accounts.first { $0.id == selectedId } }

    func account(_ id: UUID) -> ServerAccount? { accounts.first { $0.id == id } }

    func client(for id: UUID) -> SubsonicClient? {
        if let client = clients[id] { return client }
        guard let account = accounts.first(where: { $0.id == id }), let password = ServerKeychain.password(for: id) else { return nil }
        let client = SubsonicClient(account: account, password: password, away: usingAway.contains(id))
        clients[id] = client
        return client
    }

    /// The quality to stream [account]'s songs at right now: [quality], with Automatic meaning
    /// the original file at home and a 192 kbps MP3 away from home or on mobile data (only when
    /// the server converts, so nothing ever plays worse than it can).
    func streamQuality(for account: ServerAccount) -> StreamQuality {
        guard quality == .automatic else { return quality }
        let away = usingAway.contains(account.id) || networkIsExpensive
        return away && convertsToMP3[account.id] == true ? .mp3_192 : .original
    }

    // MARK: Album and artist pages

    @ObservationIgnored private var albumCache: [String: ServerAlbum] = [:]
    @ObservationIgnored private var artistCache: [String: ServerArtist] = [:]

    /// What can be shown at once for an album: as last loaded, or else as the catalog knows it.
    func cachedAlbum(_ id: String, account: UUID) -> ServerAlbum? {
        albumCache["\(account.uuidString)/\(id)"] ?? catalogs[account]?.album(id)
    }

    func cachedArtist(_ id: String, account: UUID) -> ServerArtist? {
        artistCache["\(account.uuidString)/\(id)"] ?? catalogs[account]?.artist(id)
    }

    /// An album from the server, remembered for this session so opening it again is instant.
    func album(_ id: String, account: ServerAccount) async throws -> ServerAlbum {
        let album = try await requireClient(self, account).album(id)
        albumCache["\(account.id.uuidString)/\(id)"] = album
        return album
    }

    func artist(_ id: String, account: ServerAccount) async throws -> ServerArtist {
        let artist = try await requireClient(self, account).artist(id)
        artistCache["\(account.id.uuidString)/\(id)"] = artist
        return artist
    }

    /// Loads the album of a song that started streaming, so opening it from Now Playing is instant.
    private func warmAlbum(of song: ServerSong, accountId: UUID) {
        guard let albumId = song.albumId, cachedAlbum(albumId, account: accountId) == nil, let account = account(accountId) else { return }
        Task { _ = try? await self.album(albumId, account: account) }
    }

    // MARK: Catalog (search)

    /// [account]'s catalog for search, if one has been loaded.
    func catalog(for accountId: UUID) -> ServerCatalogIndex? { catalogs[accountId] }

    /// Loads each server's saved catalog, and refreshes it from the server when it is older than
    /// [ServerCatalog.maxAge] (or missing). Not while a song streams straight from a server, and on
    /// mobile data only when there is no catalog yet.
    // MARK: Covers saved ahead

    @ObservationIgnored private var coverSync: Task<Void, Never>?
    @ObservationIgnored private var coversSyncedFor: [UUID: Int] = [:]

    /// At home on Wi-Fi, saves every album's and artist's cover (small, then large) to the phone
    /// in the background, so tiles, rows, album pages and Now Playing show covers at once, also
    /// away from home. A few at a time, pausing while a song streams; covers already saved are
    /// skipped, so it is quick after the first time.
    func syncCovers() {
        guard coverSync == nil, !networkIsExpensive else { return }
        let due = accounts.filter { account in
            !usingAway.contains(account.id) && catalogs[account.id] != nil && coversSyncedFor[account.id] != catalogVersion
        }
        guard !due.isEmpty else { return }
        let version = catalogVersion
        coverSync = Task { [weak self] in
            defer { self?.coverSync = nil }
            for account in due {
                guard let self, let index = self.catalogs[account.id], let client = self.client(for: account.id) else { continue }
                var covers: [String] = []
                var seen = Set<String>()
                for cover in index.catalog.albums.compactMap(\.coverArt) + index.catalog.artists.compactMap(\.coverArt)
                where seen.insert(cover).inserted { covers.append(cover) }
                let id = account.id
                for size in [ServerCovers.Size.small, .large] {
                    for start in stride(from: 0, to: covers.count, by: 4) {
                        // Away, on mobile data or cancelled: stop (it carries on next time at home).
                        guard !Task.isCancelled, !self.networkIsExpensive, !self.usingAway.contains(id) else { return }
                        while self.player.isStreamingDirectly, !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
                        let batch = covers[start..<min(start + 4, covers.count)]
                        await withTaskGroup(of: Void.self) { group in
                            for cover in batch {
                                let file = ServerCovers.fileURL(accountId: id, coverArt: cover, size: size)
                                if ServerCovers.hasCover(at: file) { continue }
                                let url = client.coverArtURL(cover, size: size.pixels)
                                let session = client.session
                                group.addTask { _ = await ServerCovers.download(url, to: file, session: session) }
                            }
                        }
                    }
                }
                self.coversSyncedFor[id] = version
            }
        }
    }

    func refreshCatalogs(force: Bool = false) {
        for account in accounts where catalogTasks[account.id] == nil {
            let id = account.id
            catalogTasks[id] = Task { [weak self] in
                defer { self?.catalogTasks[id] = nil }
                var saved = self?.catalogs[id]?.catalog
                if saved == nil {
                    let loaded = await Task.detached(priority: .utility) { ServerCatalog.load(id).map(ServerCatalogIndex.init) }.value
                    guard let self else { return }
                    if let loaded {
                        self.catalogs[id] = loaded
                        self.catalogVersion &+= 1
                        self.syncCovers()
                        saved = loaded.catalog
                    }
                }
                guard let self else { return }
                let stale = saved.map { Date().timeIntervalSince($0.fetchedAt) > ServerCatalog.maxAge } ?? true
                // A refresh is large: only at home on Wi-Fi and not while a song streams. Without
                // any catalog the server's music can't show in Albums and Songs, so the first one
                // is fetched anywhere, at once and not as low-priority traffic.
                let atHome = !self.usingAway.contains(id) && !self.networkIsExpensive
                let first = saved == nil
                guard first || ((force || stale) && atHome && !self.player.isStreamingDirectly),
                      let client = self.client(for: id) else { return }
                guard let fresh = try? await ServerCatalog.fetch(client, background: !first) else { return }
                let index = await Task.detached(priority: .utility) { () -> ServerCatalogIndex in
                    fresh.save(id)
                    return ServerCatalogIndex(fresh)
                }.value
                self.catalogs[id] = index
                self.catalogVersion &+= 1
                self.syncCovers()
            }
        }
        // Back home on Wi-Fi with the catalog unchanged: covers missing since are saved now.
        syncCovers()
    }

    /// Finds out once per session which servers convert to MP3 (for Automatic).
    func checkConversions() {
        for account in accounts where convertsToMP3[account.id] == nil {
            guard let client = client(for: account.id) else { continue }
            let id = account.id
            Task { [weak self] in
                guard let converts = await client.convertsToMP3() else { return }
                self?.convertsToMP3[id] = converts
            }
        }
    }

    // MARK: Home and away addresses

    /// Whether [id]'s server answered the last check (music only on it shows in Albums and
    /// Songs while it does).
    func isReachable(_ id: UUID) -> Bool { reachable.contains(id) }
    /// The selected server while it answers: its music joins the library's pages only then.
    var connectedAccount: ServerAccount? { selected.flatMap { reachable.contains($0.id) ? $0 : nil } }

    /// Checks which servers answer and, for each with an away address, uses the home address when
    /// it answers quickly, otherwise the away one. Runs at launch and whenever the network changes.
    func chooseRoutes() {
        // A check already running finishes (cancelling it each time the network or the app
        // changed meant that on mobile data it often never did, and the server's music left the
        // library's pages while songs streamed fine); then it runs once more if asked meanwhile.
        if routeTask != nil {
            routeCheckAgain = true
            return
        }
        let candidates = accounts
        guard !candidates.isEmpty else { return }
        routeTask = Task { [weak self] in
            // Let a new Wi-Fi connection settle before asking.
            try? await Task.sleep(for: .milliseconds(600))
            for account in candidates {
                guard let self, let password = ServerKeychain.password(for: account.id) else { break }
                let away = await Self.prefersAway(account: account, password: password)
                guard let away else {
                    self.reachable.remove(account.id)
                    continue
                }
                self.reachable.insert(account.id)
                if account.remoteURL != nil { self.setRoute(account.id, away: away) }
                if self.catalogs[account.id] == nil { self.refreshCatalogs() }
            }
            guard let self else { return }
            self.routeTask = nil
            if self.routeCheckAgain {
                self.routeCheckAgain = false
                self.chooseRoutes()
            }
        }
    }

    /// true: use the away address; false: the home one; nil: neither answered (left as it is).
    private nonisolated static func prefersAway(account: ServerAccount, password: String) async -> Bool? {
        let home = SubsonicClient(account: account, password: password)
        if (try? await home.ping(timeout: account.remoteURL == nil ? 8 : 3)) != nil { return false }
        guard account.remoteURL != nil else { return nil }
        let away = SubsonicClient(account: account, password: password, away: true)
        if (try? await away.ping(timeout: 8)) != nil { return true }
        return nil
    }

    private func setRoute(_ id: UUID, away: Bool) {
        guard usingAway.contains(id) != away else { return }
        if away { usingAway.insert(id) } else { usingAway.remove(id) }
        clients[id] = nil
        // The other address may reach a different setup (rare), and the first check may have
        // failed for lack of a connection: check again.
        convertsToMP3[id] = nil
        checkConversions()
    }

    /// Sets (or, with an empty [address], removes) a server's away-from-home address after
    /// checking that it answers.
    func setRemote(_ address: String, for account: ServerAccount) async throws {
        var updated = account
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            updated.remoteURL = nil
        } else {
            guard let url = ServerAccount.normalizedRemoteURL(from: text) else { throw SubsonicError.invalidRemoteAddress }
            updated.remoteURL = url
            guard let password = ServerKeychain.password(for: account.id) else { throw SubsonicError.missingPassword }
            _ = try await SubsonicClient(account: updated, password: password, away: true).ping(timeout: 15)
        }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = updated
        saveAccounts()
        usingAway.remove(account.id)
        clients[account.id] = nil
        chooseRoutes()
    }

    /// Checks the address and sign-in with the server, then saves the account (password in the
    /// Keychain). With an away address, either address answering is enough, so a server can be
    /// added from anywhere.
    func add(name: String, address: String, remote: String = "", username: String, password: String) async throws -> ServerAccount {
        guard let url = ServerAccount.normalizedURL(from: address) else { throw SubsonicError.invalidAddress }
        let remoteText = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var remoteURL: URL?
        if !remoteText.isEmpty {
            guard let parsed = ServerAccount.normalizedRemoteURL(from: remoteText) else { throw SubsonicError.invalidRemoteAddress }
            remoteURL = parsed
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        let label = name.trimmingCharacters(in: .whitespaces)
        let account = ServerAccount(id: UUID(), name: label.isEmpty ? (url.host ?? "Erhu Server") : label, baseURL: url,
                                    username: user, remoteURL: remoteURL)
        var away = false
        do {
            _ = try await SubsonicClient(account: account, password: password).ping(timeout: remoteURL == nil ? 20 : 5)
        } catch {
            // A wrong password is wrong at either address; otherwise try the away address.
            if case .server(40, _)? = error as? SubsonicError { throw error }
            guard remoteURL != nil else { throw error }
            _ = try await SubsonicClient(account: account, password: password, away: true).ping()
            away = true
        }
        guard ServerKeychain.setPassword(password, for: account.id) else {
            throw SubsonicError.server(code: 0, message: String(localized: "Couldn't save the password in the Keychain."))
        }
        if away { usingAway.insert(account.id) }
        reachable.insert(account.id)
        clients[account.id] = SubsonicClient(account: account, password: password, away: away)
        accounts.append(account)
        saveAccounts()
        selectedId = account.id
        adoptRecents(of: account)
        checkConversions()
        refreshCatalogs()
        return account
    }

    /// Handles an erhu:// link. True if it was a pairing link.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let invite = ServerInvite(url: url) else { return false }
        pendingInvite = invite
        return true
    }

    func remove(_ account: ServerAccount) {
        catalogs[account.id] = nil
        try? FileManager.default.removeItem(at: ServerCatalog.file(for: account.id))
        ServerKeychain.removePassword(for: account.id)
        clients[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        usingAway.remove(account.id)
        reachable.remove(account.id)
        saveAccounts()
        if selectedId == account.id { selectedId = accounts.first?.id }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Keys.accounts) }
    }

    // MARK: Streaming

    /// Streams [songs] from [account], starting with the song at [index].
    /// Now Playing names [source] ("Streaming: <album>").
    /// [shuffled] nil keeps the shuffle mode as it is (tapping a song), as the library's lists do.
    func play(_ songs: [ServerSong], startAt index: Int = 0, shuffled: Bool? = nil, account: ServerAccount, source: PlaybackSource? = nil) {
        let playable = streamSongs(songs, account: account)
        guard !playable.isEmpty else { return }
        if let shuffled { player.setShuffleModeEnabled(shuffled) }
        let start = shuffled == true ? Int.random(in: 0..<playable.count) : min(max(index, 0), playable.count - 1)
        player.playCollection(playable, startIndex: start, origin: nil,
                              source: source ?? .server(account: account.id, album: nil, title: account.name))
        // Home's Recently streamed albums follows what was played, even before the song arrives.
        let started = songs.filter { $0.isVideo != true }
        if started.indices.contains(start), playable[start].isStream,
           let album = StreamedAlbum(StreamedSong(accountId: account.id, song: started[start], playedAt: Date(),
                                                  server: account.baseURL.absoluteString, username: account.username)) {
            noteAlbum(album)
        }
    }

    /// Playable songs for [songs], with each one's favourite mark as the server (or this session) has it.
    /// A song the library already has comes back as the library's (it plays from the phone, with
    /// its own tags and cover); the others stream.
    func streamSongs(_ songs: [ServerSong], account: ServerAccount) -> [Song] {
        songs.filter { $0.isVideo != true }.map {
            librarySong(matching: $0)
                ?? ServerStream.shared.song(for: $0, account: account, quality: streamQuality(for: account), favourite: isFavourite($0, account: account))
        }
    }

    /// The library's songs by normalized title, rebuilt when the songs change.
    @ObservationIgnored private var songsByTitle: (signature: [Int64], songs: [String: [Song]]) = ([], [:])

    /// The library's copy of [remote] (same title and artist), if it has one.
    func librarySong(matching remote: ServerSong) -> Song? {
        let songs = library.songs
        let signature: [Int64] = [Int64(songs.count), songs.first?.id ?? 0, songs.last?.id ?? 0]
        if signature != songsByTitle.signature {
            songsByTitle = (signature, Dictionary(grouping: songs) { SearchNormalizer.normalize($0.title) })
        }
        return songsByTitle.songs[SearchNormalizer.normalize(remote.title)]?
            .first { ServerLibraryMerge.sameArtist($0.artist, remote.artist ?? "") }
    }

    /// The library's albums by normalized title, rebuilt when the albums change.
    @ObservationIgnored private var albumsByTitle: (signature: [Int64], albums: [String: [Album]]) = ([], [:])

    /// The library's album [remote] belongs to (same title, same artist), and the song whose
    /// cover it shows.
    private func libraryAlbum(of remote: ServerSong) -> (albumId: Int64, coverSong: URL?)? {
        guard let title = remote.album, !title.isEmpty, let album = libraryAlbum(named: title, artist: remote.artist ?? "") else { return nil }
        return (album.id, library.albumCoverSong[album.id]?.url)
    }

    /// The library's album titled [title] by [artist], if it has one.
    func libraryAlbum(named title: String, artist: String) -> Album? {
        let albums = library.albums
        // Cheap to compare for every song; a rescan that changes albums changes these.
        let signature: [Int64] = [Int64(albums.count), albums.first?.id ?? 0, albums.last?.id ?? 0]
        if signature != albumsByTitle.signature {
            albumsByTitle = (signature, Dictionary(grouping: albums) { SearchNormalizer.normalize($0.title) })
        }
        return albumsByTitle.albums[SearchNormalizer.normalize(title)]?.first { ServerLibraryMerge.sameArtist($0.artist, artist) }
    }

    // MARK: Artists

    /// The library's artists by normalized name, rebuilt when the artists change.
    @ObservationIgnored private var artistsByKey: (signature: [Int64], artists: [String: Artist]) = ([], [:])
    @ObservationIgnored private var namedArtistsCache: (key: String, artists: [String: NamedServerArtist])?

    private var libraryArtistsByKey: [String: Artist] {
        let artists = library.artists
        let signature: [Int64] = [Int64(artists.count), artists.first?.id ?? 0, artists.last?.id ?? 0]
        if signature != artistsByKey.signature {
            artistsByKey = (signature, Dictionary(artists.map { (ServerLibraryMerge.artistKey($0.name), $0) },
                                                  uniquingKeysWith: { a, b in a.songCount >= b.songCount ? a : b }))
        }
        return artistsByKey.artists
    }

    var libraryArtistKeys: Set<String> { Set(libraryArtistsByKey.keys) }

    func libraryArtist(named name: String) -> Artist? { libraryArtistsByKey[ServerLibraryMerge.artistKey(name)] }

    /// The artists [credit] names, each to open on its own.
    func artistNames(in credit: String) -> [String] {
        let server = connectedAccount.flatMap { catalog(for: $0.id) }.map { Set($0.catalog.artists.map { ServerLibraryMerge.artistKey($0.name) }) } ?? []
        return ServerLibraryMerge.artistNames(credit, local: libraryArtistKeys, server: server)
    }

    /// The connected server's artists by name (empty while it doesn't answer).
    func namedArtists() async -> [String: NamedServerArtist] {
        guard let account = connectedAccount, let index = catalog(for: account.id) else { return [:] }
        let local = libraryArtistKeys
        let key = "\(account.id)|\(catalogVersion)|\(artistsByKey.signature)"
        if let cached = namedArtistsCache, cached.key == key { return cached.artists }
        let artists = await Task.detached(priority: .userInitiated) { ServerLibraryMerge.namedArtists(in: index, local: local) }.value
        namedArtistsCache = (key, artists)
        return artists
    }

    /// The page for artist [name] of [song]: the library's artist (which lists their streamed
    /// music too), else the connected server's, else the server artist the song names.
    func artistRoute(named name: String, of song: Song) async -> Route? {
        if let artist = libraryArtist(named: name) { return .artist(artist.id) }
        if let account = connectedAccount, await namedArtists()[ServerLibraryMerge.artistKey(name)] != nil {
            return .serverArtistNamed(ServerRef(accountId: account.id, id: ServerLibraryMerge.artistKey(name), title: name))
        }
        if song.isStream, let found = ServerStream.shared.remote(for: song), let id = found.song.artistId {
            return .serverArtist(ServerRef(accountId: found.accountId, id: id, title: found.song.artist ?? song.artist))
        }
        return song.artistId > 0 ? .artist(song.artistId) : nil
    }

    /// What a streamed song's row menu offers: queueing, the server favourite and downloading.
    func songActions(source: PlaybackSource) -> SongActions {
        // Server pages can list library songs too (the phone's copy of a song comes first).
        SongActions(toggleFavorite: { [weak self] in self?.actions.toggleFavorite($0) },
                    playNext: { [weak self] in self?.actions.playNext($0, source: source) },
                    addToQueue: { [weak self] in self?.actions.addToQueue($0, source: source) },
                    startRadio: { _ in }, addToPlaylist: { _ in })
    }

    // MARK: Recently streamed

    private func noteStreamed(_ song: ServerSong, accountId: UUID) {
        if recentlyStreamed.first?.song.id == song.id, recentlyStreamed.first?.accountId == accountId { return }
        let account = accounts.first { $0.id == accountId }
        let item = StreamedSong(accountId: accountId, song: song, playedAt: Date(),
                                server: account?.baseURL.absoluteString ?? "", username: account?.username ?? "")
        recentlyStreamed = Self.addingRecent(item, to: recentlyStreamed)
        saveRecent()
        if let album = StreamedAlbum(item) { noteAlbum(album) }
        warmAlbum(of: song, accountId: accountId)
    }

    /// Puts [album] first on Home's Recently streamed albums. An album pushed off the list loses
    /// its saved cover.
    private func noteAlbum(_ album: StreamedAlbum) {
        let (list, dropped) = Self.addingAlbum(album, to: recentAlbums)
        if list != recentAlbums {
            recentAlbums = list
            for gone in dropped { try? FileManager.default.removeItem(at: gone.coverFile) }
            if let data = try? JSONEncoder().encode(recentAlbums) { UserDefaults.standard.set(data, forKey: Keys.recentAlbums) }
        }
        saveCover(of: album)
    }

    /// [album] first, an earlier entry for the same album replaced, at most [limit]; also returns
    /// the albums that fell off the end.
    nonisolated static func addingAlbum(_ album: StreamedAlbum, to list: [StreamedAlbum],
                                        limit: Int = albumLimit) -> (list: [StreamedAlbum], dropped: [StreamedAlbum]) {
        let all = [album] + list.filter { $0.id != album.id }
        return (Array(all.prefix(limit)), Array(all.dropFirst(limit)))
    }

    /// Keeps a copy of [album]'s cover on this device: from the streaming cover cache when it is
    /// there, otherwise fetched from its server (when connected).
    func saveCover(of album: StreamedAlbum) {
        let target = album.coverFile
        guard !FileManager.default.fileExists(atPath: target.path), let coverArt = album.coverArt else { return }
        let account = self.account(album.accountId, server: album.server, username: album.username)
        let cached = ServerCovers.fileURL(accountId: account?.id ?? album.accountId, coverArt: coverArt)
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: cached, to: target)) != nil {
                NotificationCenter.default.post(name: ServerCovers.didChange, object: target.path)
            }
        } else if let account, let client = client(for: account.id) {
            ServerCovers.fetch(client.coverArtURL(coverArt, size: 800), to: target, session: client.session)
        }
    }

    /// [recent] with [item] first, any earlier entry for the same song removed, capped at [recentLimit].
    nonisolated static func addingRecent(_ item: StreamedSong, to recent: [StreamedSong]) -> [StreamedSong] {
        var list = recent.filter { !($0.accountId == item.accountId && $0.song.id == item.song.id) }
        list.insert(item, at: 0)
        return Array(list.prefix(recentLimit))
    }

    /// The server a recently streamed song came from, or nil if that server was removed.
    /// A server that was removed and added again has a new ID, so the address and user also match.
    func account(for item: StreamedSong) -> ServerAccount? {
        account(item.accountId, server: item.server, username: item.username)
    }

    /// The account [id], or the one with the same address and user (a server added again).
    func account(_ id: UUID, server: String, username: String) -> ServerAccount? {
        accounts.first { $0.id == id }
            ?? accounts.first { !server.isEmpty && $0.baseURL.absoluteString == server && $0.username == username }
    }

    /// Streams the recent songs from [item]'s server, starting with [item]. False if that server
    /// is no longer connected, so the page can ask the listener to connect again.
    @discardableResult
    func playRecent(_ item: StreamedSong) -> Bool {
        guard let account = account(for: item) else { return false }
        let sameServer = recentlyStreamed.filter { self.account(for: $0)?.id == account.id }
        let index = sameServer.firstIndex { $0.song.id == item.song.id } ?? 0
        play(sameServer.map(\.song), startAt: index, account: account)
        return true
    }

    /// Plays a Recently streamed album whose server has no album ID for it: the songs of it
    /// streamed lately.
    func playRecent(_ album: StreamedAlbum) -> Bool {
        guard let first = recentlyStreamed.first(where: { StreamedAlbum($0)?.id == album.id }) else { return false }
        return playRecent(first)
    }

    /// Songs streamed from a server that was removed and is now added again (same address and
    /// user) move to the new account, so Recently streamed shows their covers and plays them.
    private func adoptRecents(of account: ServerAccount) {
        let server = account.baseURL.absoluteString
        var changed = false
        recentlyStreamed = recentlyStreamed.map { item in
            guard item.accountId != account.id, item.server == server, item.username == account.username,
                  !accounts.contains(where: { $0.id == item.accountId }) else { return item }
            changed = true
            return StreamedSong(accountId: account.id, song: item.song, playedAt: item.playedAt, server: item.server, username: item.username)
        }
        if changed { saveRecent() }
    }

    func clearRecentlyStreamed() {
        recentlyStreamed = []
        saveRecent()
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recentlyStreamed) { UserDefaults.standard.set(data, forKey: Keys.recent) }
    }

    // MARK: Favourites

    /// Flips a streamed song's favourite on its server.
    func toggleFavourite(stream song: Song) {
        guard let found = ServerStream.shared.remote(for: song), let account = account(found.accountId) else {
            actions.show(String(localized: "Server not connected"))
            return
        }
        let favourite = !isFavourite(found.song, account: account)
        setFavourite(found.song, favourite, account: account)
        actions.show(favourite ? String(localized: "Added to server favourites") : String(localized: "Removed from server favourites"))
    }

    func isFavourite(_ song: ServerSong, account: ServerAccount) -> Bool {
        favouriteChanges["\(account.id.uuidString)/\(song.id)"] ?? (song.starred != nil)
    }

    /// Marks [song] as a favourite on the server (or removes the mark) and remembers it for this session.
    func setFavourite(_ song: ServerSong, _ favourite: Bool, account: ServerAccount) {
        guard let client = client(for: account.id) else { return }
        let key = "\(account.id.uuidString)/\(song.id)"
        let before = favouriteChanges[key]
        favouriteChanges[key] = favourite
        Task {
            do {
                try await client.setStarred(song.id, favourite)
            } catch {
                favouriteChanges[key] = before
                actions.show(String(localized: "Couldn't change the favourite: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Downloads

    /// Where a downloaded song is saved in the Erhu folder: From Server/Artist/Album/NN Title.ext
    nonisolated static func downloadPath(for song: ServerSong) -> String {
        func clean(_ text: String?, fallback: String) -> String {
            let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
            var value = (text ?? "").components(separatedBy: banned).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            while value.hasPrefix(".") { value.removeFirst() }
            value = String(value.prefix(120)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? fallback : value
        }
        let artist = clean(song.artist, fallback: "Unknown Artist")
        let album = clean(song.album, fallback: "Unknown Album")
        let title = clean(song.title, fallback: "Track")
        let number = (song.track ?? 0) > 0 ? String(format: "%02d ", song.track!) : ""
        let disc = (song.discNumber ?? 1) > 1 ? "\(song.discNumber!)-" : ""
        return "From Server/\(artist)/\(album)/\(disc)\(number)\(title).\(song.fileExtension)"
    }

    func isDownloaded(_ song: ServerSong) -> Bool {
        FileManager.default.fileExists(atPath: LibraryPaths.musicFolder.appendingPathComponent(Self.downloadPath(for: song)).path)
    }

    /// Whether a streamed song's original file is already in the Erhu folder.
    func isDownloaded(stream song: Song) -> Bool {
        ServerStream.shared.remote(for: song).map { isDownloaded($0.song) } ?? false
    }

    /// Saves a streamed song (Now Playing's or a row's menu) to this device.
    func download(stream song: Song) {
        guard let found = ServerStream.shared.remote(for: song), let account = account(found.accountId) else {
            actions.show(String(localized: "Server not connected"))
            return
        }
        download([found.song], account: account)
    }

    var isDownloading: Bool { downloads.contains { $0.state == .waiting || $0.state == .downloading } }

    /// Saves the original files of [songs] into the Erhu folder, one at a time, then rescans the library.
    func download(_ songs: [ServerSong], account: ServerAccount) {
        let new = songs.filter { song in song.isVideo != true && !downloads.contains { $0.song.id == song.id && $0.accountId == account.id && $0.state != .failed } }
        guard !new.isEmpty else { return }
        downloads.removeAll { download in download.state == .failed && new.contains { $0.id == download.song.id } }
        downloads += new.map { ServerDownload(song: $0, accountId: account.id, state: isDownloaded($0) ? .alreadySaved : .waiting) }
        startDownloads()
        let count = downloads.filter { $0.state == .waiting }.count
        if count > 0 { actions.show(String(localized: "Downloading \(countLabel(count, .song)) to this device")) }
        else { actions.show(String(localized: "Already on this device")) }
    }

    func cancelDownloads() {
        downloadTask?.cancel()
        downloadTask = nil
        for index in downloads.indices where downloads[index].state == .waiting || downloads[index].state == .downloading {
            downloads[index].state = .failed
            downloads[index].message = String(localized: "Cancelled")
        }
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.state != .waiting && $0.state != .downloading }
    }

    private func startDownloads() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            var saved = 0
            while let self, !Task.isCancelled, let index = self.downloads.firstIndex(where: { $0.state == .waiting }) {
                let item = self.downloads[index]
                self.downloads[index].state = .downloading
                guard let client = self.client(for: item.accountId) else {
                    self.finish(item.id, .failed, SubsonicError.missingPassword.errorDescription)
                    continue
                }
                let target = LibraryPaths.musicFolder.appendingPathComponent(Self.downloadPath(for: item.song))
                do {
                    try await Self.save(client.downloadURL(item.song.id), to: target, session: client.session)
                    self.finish(item.id, .saved, nil)
                    saved += 1
                } catch {
                    self.finish(item.id, .failed, error.localizedDescription)
                }
            }
            guard let self else { return }
            self.downloadTask = nil
            if saved > 0 {
                self.library.scan()
                self.actions.show(String(localized: "Saved \(countLabel(saved, .song)) to this device"))
            }
        }
    }

    private func finish(_ id: UUID, _ state: ServerDownload.State, _ message: String?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
        downloads[index].message = message
    }

    /// Downloads [url] to a temporary file and moves it into place, so a cancelled or failed
    /// download never leaves half a song in the library.
    private nonisolated static func save(_ url: URL, to target: URL, session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let type = (response.mimeType ?? "").lowercased()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) || type.contains("json") || type.contains("xml") {
            _ = try SubsonicClient.decode((try? Data(contentsOf: temporary)) ?? Data(), response: response)
            throw ServerStreamError.notAudio
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { return }
        try FileManager.default.moveItem(at: temporary, to: target)
    }
}

/// One song being saved from a server to this device.
struct ServerDownload: Identifiable, Hashable {
    enum State: Hashable { case waiting, downloading, saved, alreadySaved, failed }

    let id = UUID()
    let song: ServerSong
    let accountId: UUID
    var state: State
    var message: String?
}

/// A song streamed lately: which server it came from and what is needed to play it again.
struct StreamedSong: Codable, Hashable, Identifiable, Sendable {
    let accountId: UUID
    let song: ServerSong
    let playedAt: Date
    /// The server's address and user when the song was streamed.
    var server = ""
    var username = ""
    var id: String { "\(accountId.uuidString)/\(song.id)" }
}

/// An album on Home's Recently streamed shelf: what is needed to show and open it, also when
/// its server isn't connected.
struct StreamedAlbum: Codable, Hashable, Identifiable, Sendable {
    let accountId: UUID
    var server = ""
    var username = ""
    /// The album's ID on the server (nil if the server didn't say).
    let albumId: String?
    let title: String
    let artist: String?
    let coverArt: String?

    /// The same album from a server added again is the same entry.
    var id: String { "\(server)|\(username)|\(albumId ?? "\(title)|\(artist ?? "")")" }

    /// The album of a streamed song (nil when the song names no album).
    init?(_ item: StreamedSong) {
        guard item.song.albumId != nil || !(item.song.album ?? "").isEmpty else { return nil }
        accountId = item.accountId
        server = item.server
        username = item.username
        albumId = item.song.albumId
        title = item.song.album ?? String(localized: "Unknown")
        artist = item.song.artist
        coverArt = item.song.coverArt
    }

    /// Where its cover is kept on this device (Application Support, so iOS never clears it).
    var coverFile: URL {
        LibraryPaths.supportFolder.appendingPathComponent("streamed-album-covers", isDirectory: true)
            .appendingPathComponent(String(ServerStreamPaths.hash(id), radix: 16) + ".img")
    }
}
