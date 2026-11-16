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
    /// Favourite changes made in this session, by "account/song", shown before the server list is reloaded.
    private(set) var favouriteChanges: [String: Bool] = [:]
    /// A pairing link (QR code from the Erhu Server app) waiting to be shown as a filled-in Add server sheet.
    var pendingInvite: ServerInvite?
    /// Servers reached through their away-from-home address right now.
    private(set) var usingAway: Set<UUID> = []

    @ObservationIgnored private var clients: [UUID: SubsonicClient] = [:]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let actions: LibraryActions
    @ObservationIgnored private let player: PlayerController

    private enum Keys {
        static let accounts = "musicServer.accounts"
        static let selected = "musicServer.selected"
        static let quality = "musicServer.streamQuality"
        static let recent = "musicServer.recentlyStreamed"
    }
    static let recentLimit = 100

    init(library: LibraryStore, actions: LibraryActions, player: PlayerController) {
        self.library = library
        self.actions = actions
        self.player = player
        quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: Keys.quality) ?? "") ?? .original
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
        ServerStream.shared.clientProvider = { [weak self] id in self?.client(for: id) }
        ServerStream.shared.onStarted = { [weak self] accountId, song in self?.noteStreamed(song, accountId: accountId) }
        ServerStream.shared.trimCache()
        actions.streamFavorite = { [weak self] song in self?.toggleFavourite(stream: song) }
        // Joining or leaving a Wi-Fi network decides between the home and away addresses.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.chooseRoutes() }
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

    // MARK: Home and away addresses

    /// For each server with an away address: the home address when it answers quickly, otherwise
    /// the away address. Runs at launch and whenever the network changes.
    func chooseRoutes() {
        routeTask?.cancel()
        let candidates = accounts.filter { $0.remoteURL != nil }
        guard !candidates.isEmpty else { return }
        routeTask = Task { [weak self] in
            // Let a new Wi-Fi connection settle before asking.
            try? await Task.sleep(for: .milliseconds(600))
            for account in candidates {
                guard !Task.isCancelled, let self, let password = ServerKeychain.password(for: account.id) else { return }
                let away = await Self.prefersAway(account: account, password: password)
                guard !Task.isCancelled, let away else { continue }
                self.setRoute(account.id, away: away)
            }
        }
    }

    /// true: use the away address; false: the home one; nil: neither answered (left as it is).
    private nonisolated static func prefersAway(account: ServerAccount, password: String) async -> Bool? {
        let home = SubsonicClient(account: account, password: password)
        if (try? await home.ping(timeout: 3)) != nil { return false }
        let away = SubsonicClient(account: account, password: password, away: true)
        if (try? await away.ping(timeout: 8)) != nil { return true }
        return nil
    }

    private func setRoute(_ id: UUID, away: Bool) {
        guard usingAway.contains(id) != away else { return }
        if away { usingAway.insert(id) } else { usingAway.remove(id) }
        clients[id] = nil
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
        clients[account.id] = SubsonicClient(account: account, password: password, away: away)
        accounts.append(account)
        saveAccounts()
        selectedId = account.id
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
        ServerKeychain.removePassword(for: account.id)
        clients[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        usingAway.remove(account.id)
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
    }

    /// Playable songs for [songs], with each one's favourite mark as the server (or this session) has it.
    func streamSongs(_ songs: [ServerSong], account: ServerAccount) -> [Song] {
        songs.filter { $0.isVideo != true }.map {
            ServerStream.shared.song(for: $0, account: account, quality: quality, favourite: isFavourite($0, account: account))
        }
    }

    /// What a streamed song's row menu offers: queueing, the server favourite and downloading.
    func songActions(source: PlaybackSource) -> SongActions {
        SongActions(toggleFavorite: { [weak self] in self?.toggleFavourite(stream: $0) },
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
        accounts.first { $0.id == item.accountId }
            ?? accounts.first { !item.server.isEmpty && $0.baseURL.absoluteString == item.server && $0.username == item.username }
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

    /// The last five albums streamed, newest first (Home's Recently streamed albums).
    var recentAlbums: [StreamedAlbum] { Self.recentAlbums(from: recentlyStreamed) }

    nonisolated static func recentAlbums(from recent: [StreamedSong], limit: Int = 5) -> [StreamedAlbum] {
        var seen = Set<String>()
        var albums: [StreamedAlbum] = []
        for item in recent {
            guard let albumId = item.song.albumId, seen.insert("\(item.accountId.uuidString)/\(albumId)").inserted else { continue }
            albums.append(StreamedAlbum(item: item, albumId: albumId))
            if albums.count == limit { break }
        }
        return albums
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

/// An album on Home's Recently streamed shelf, from the newest song streamed from it.
struct StreamedAlbum: Identifiable, Hashable, Sendable {
    let item: StreamedSong
    let albumId: String
    var id: String { "\(item.accountId.uuidString)/\(albumId)" }
    var accountId: UUID { item.accountId }
    var title: String { item.song.album ?? String(localized: "Unknown") }
    var artist: String? { item.song.artist }
    var coverArt: String? { item.song.coverArt }
}
