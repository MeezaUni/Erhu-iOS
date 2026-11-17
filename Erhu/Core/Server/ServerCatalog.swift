import Foundation

/// Everything on a music server, kept on this device (Application Support/Erhu/server-catalog), so search finds
/// server music instantly, with the same forgiving matching as the library (partial words, accents,
/// "title artist"), instead of asking the server on every keystroke. Refreshed in the background.
struct ServerCatalog: Codable, Sendable {
    struct Artist: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let coverArt: String?
        let albumCount: Int?
    }

    struct Album: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let artist: String?
        let coverArt: String?
        let year: Int?
        /// Missing in catalogs saved by earlier versions.
        var artistId: String? = nil
    }

    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [ServerSong] = []
    var fetchedAt = Date.distantPast

    static let pageSize = 500
    /// A catalog this old is refreshed when search opens or the app starts.
    static let maxAge: TimeInterval = 30 * 60

    /// Kept with the app's data, not in Caches: iOS empties Caches when storage runs low, and
    /// without a catalog the server's music leaves Albums and Songs until it is fetched again.
    static func file(for accountId: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("Erhu/server-catalog", isDirectory: true)
            .appendingPathComponent(accountId.uuidString + ".json")
    }

    /// Where earlier versions kept it.
    private static func oldFile(for accountId: UUID) -> URL {
        LibraryPaths.cachesFolder.appendingPathComponent("server-catalog", isDirectory: true)
            .appendingPathComponent(accountId.uuidString + ".json")
    }

    static func load(_ accountId: UUID) -> ServerCatalog? {
        guard let data = (try? Data(contentsOf: file(for: accountId))) ?? (try? Data(contentsOf: oldFile(for: accountId))) else { return nil }
        return try? JSONDecoder().decode(ServerCatalog.self, from: data)
    }

    func save(_ accountId: UUID) {
        let url = Self.file(for: accountId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Downloads the whole catalog, a page of each kind at a time.
    static func fetch(_ client: SubsonicClient, background: Bool = true) async throws -> ServerCatalog {
        var catalog = ServerCatalog()
        var artistOffset = 0, albumOffset = 0, songOffset = 0
        while artistOffset >= 0 || albumOffset >= 0 || songOffset >= 0 {
            try Task.checkCancellation()
            let page = try await client.catalogPage(artistOffset: artistOffset, albumOffset: albumOffset,
                                                    songOffset: songOffset, size: pageSize, background: background)
            let artists = page?.artist ?? [], albums = page?.album ?? [], songs = page?.song ?? []
            catalog.artists += artists.map { Artist(id: $0.id, name: $0.name, coverArt: $0.coverArt, albumCount: $0.albumCount) }
            catalog.albums += albums.map { Album(id: $0.id, name: $0.name, artist: $0.artist, coverArt: $0.coverArt, year: $0.year, artistId: $0.artistId) }
            catalog.songs += songs.filter { $0.isVideo != true }
            // A kind is done when a page comes back short; -1 stops asking for it.
            artistOffset = artistOffset < 0 || artists.count < pageSize ? -1 : artistOffset + artists.count
            albumOffset = albumOffset < 0 || albums.count < pageSize ? -1 : albumOffset + albums.count
            songOffset = songOffset < 0 || songs.count < pageSize ? -1 : songOffset + songs.count
        }
        catalog.fetchedAt = Date()
        return catalog
    }
}

/// Searches a [ServerCatalog] with the library's own matching ([SearchNormalizer]: prefixes,
/// partial words, accents, small typos, "title artist"). Songs, albums and artists are ranked on
/// their own, so every matching song shows (two songs of the same name by different artists).
extension ServerCatalog {
    /// Albums the server keeps as several (one per album-artist tag): split album id -> the id
    /// of the one kept (the one with the most songs, by [songCount]).
    static func splitAlbums(_ albums: [Album], songCount: (String) -> Int) -> [String: String] {
        var groups: [String: [Album]] = [:]
        for album in albums {
            groups[SearchNormalizer.normalize(album.name) + "|\(album.year ?? 0)", default: []].append(album)
        }
        var aliases: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            var remaining = group.sorted { songCount($0.id) > songCount($1.id) }
            while let kept = remaining.first {
                remaining.removeFirst()
                let parts = remaining.filter { ServerLibraryMerge.sameArtist($0.artist ?? "", kept.artist ?? "") }
                for part in parts { aliases[part.id] = kept.id }
                remaining.removeAll { aliases[$0.id] != nil }
            }
        }
        return aliases
    }

    /// [songs] without copies: the same title, artist and album, within two seconds of the same
    /// length (a server with the same file twice). The first of each stays.
    static func uniqueSongs(_ songs: [ServerSong]) -> [ServerSong] {
        func key(_ song: ServerSong) -> String {
            [song.title, song.artist ?? "", song.album ?? ""].map(SearchNormalizer.normalize).joined(separator: "|")
        }
        var kept: [String: [Int]] = [:]
        return songs.filter { song in
            let k = key(song), length = song.duration ?? 0
            if kept[k]?.contains(where: { abs($0 - length) <= 2 }) == true { return false }
            kept[k, default: []].append(length)
            return true
        }
    }
}

final class ServerCatalogIndex: @unchecked Sendable {
    let catalog: ServerCatalog
    // Names folded once, so a search only compares.
    private let songTitles: [String]
    private let songArtists: [String]
    private let albumNames: [String]
    private let albumArtists: [String]
    private let artistNames: [String]

    private let songsByAlbum: [String: [Int]]
    private let albumsById: [String: Int]
    private let artistsById: [String: Int]
    private let songsById: [String: Int]

    init(_ catalog: ServerCatalog) {
        var catalog = catalog
        catalog.songs = ServerCatalog.uniqueSongs(catalog.songs)
        var byAlbum: [String: [Int]] = [:]
        for (index, song) in catalog.songs.enumerated() { if let album = song.albumId { byAlbum[album, default: []].append(index) } }
        // One album the server split in several (one per album-artist tag, e.g. "Doja Cat" and
        // "Doja Cat, The Weeknd" for tracks of Planet Her): the same name and year, sharing an
        // artist. They become one album, the one with the most songs, holding all their songs;
        // asking for any of their ids finds it.
        let aliases = ServerCatalog.splitAlbums(catalog.albums) { byAlbum[$0]?.count ?? 0 }
        for (alias, canonical) in aliases {
            byAlbum[canonical, default: []] += byAlbum.removeValue(forKey: alias) ?? []
        }
        catalog.albums.removeAll { aliases[$0.id] != nil }
        self.catalog = catalog
        songsByAlbum = byAlbum
        var albumIndex = Dictionary(catalog.albums.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (alias, canonical) in aliases { albumIndex[alias] = albumIndex[canonical] }
        albumsById = albumIndex
        artistsById = Dictionary(catalog.artists.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        songsById = Dictionary(catalog.songs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        songTitles = catalog.songs.map { SearchNormalizer.normalizeWords($0.title) }
        songArtists = catalog.songs.map { SearchNormalizer.normalizeWords($0.artist ?? "") }
        albumNames = catalog.albums.map { SearchNormalizer.normalizeWords($0.name) }
        albumArtists = catalog.albums.map { SearchNormalizer.normalizeWords($0.artist ?? "") }
        artistNames = catalog.artists.map { SearchNormalizer.normalizeWords($0.name) }
    }

    func search(_ query: String, limit: Int) -> (artists: [ServerCatalog.Artist], albums: [ServerCatalog.Album], songs: [ServerSong]) {
        let text = SearchNormalizer.normalizeWords(query)
        guard !text.isEmpty else { return ([], [], []) }
        let tokens = text.split(separator: " ").map(String.init)
        /// "somebody else 1975": the name matches some words and the artist the others.
        func qualified(_ name: String, _ artist: String) -> Int {
            guard tokens.count >= 2, !artist.isEmpty, tokens.indices.contains(where: { index in
                SearchNormalizer.matches(name, tokens[index]) && tokens.indices.contains { $0 != index && SearchNormalizer.matches(artist, tokens[$0]) }
            }) else { return 0 }
            switch SearchNormalizer.score(name + " " + artist, text) {
            case 100: return 98
            case 90...: return 92
            case 75...: return 88
            case 60...: return 55
            default: return 0
            }
        }
        func ranked(_ count: Int, _ score: (Int) -> Int) -> [Int] {
            var scored: [(index: Int, score: Int)] = []
            for index in 0..<count {
                let value = score(index)
                if value > 0 { scored.append((index, value)) }
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            return scored.prefix(limit).map(\.index)
        }
        let songs = ranked(catalog.songs.count) { max(SearchNormalizer.score(self.songTitles[$0], text), qualified(self.songTitles[$0], self.songArtists[$0])) }
        let albums = ranked(catalog.albums.count) { max(SearchNormalizer.score(self.albumNames[$0], text), qualified(self.albumNames[$0], self.albumArtists[$0])) }
        let artists = ranked(catalog.artists.count) { SearchNormalizer.score(self.artistNames[$0], text) }
        return (artists.map { catalog.artists[$0] }, albums.map { catalog.albums[$0] }, songs.map { catalog.songs[$0] })
    }

    /// An album as the catalog knows it (songs in disc and track order), to show at once.
    /// The songs with [ids], in that order (unknown ones left out).
    func songs(_ ids: [String]) -> [ServerSong] { ids.compactMap { songsById[$0].map { catalog.songs[$0] } } }

    /// The catalog's entry for album [id].
    func albumEntry(_ id: String) -> ServerCatalog.Album? { albumsById[id].map { catalog.albums[$0] } }

    func songCount(ofAlbum id: String) -> Int {
        guard let index = albumsById[id] else { return songsByAlbum[id]?.count ?? 0 }
        return songsByAlbum[catalog.albums[index].id]?.count ?? 0
    }

    func album(_ id: String) -> ServerAlbum? {
        guard let index = albumsById[id] else { return nil }
        let album = catalog.albums[index]
        let songs = (songsByAlbum[album.id] ?? []).map { catalog.songs[$0] }.sorted {
            ($0.discNumber ?? 1, $0.track ?? 0, $0.title) < ($1.discNumber ?? 1, $1.track ?? 0, $1.title)
        }
        return ServerAlbum(id: album.id, name: album.name, artist: album.artist, artistId: album.artistId,
                           coverArt: album.coverArt, year: album.year, song: songs)
    }

    /// An artist and their albums as the catalog knows them (albums need an artist ID, which
    /// catalogs saved by earlier versions lack: then nil, and the page waits for the server).
    func artist(_ id: String) -> ServerArtist? {
        guard let index = artistsById[id] else { return nil }
        let albums = catalog.albums.filter { $0.artistId == id }
        guard !albums.isEmpty else { return nil }
        let artist = catalog.artists[index]
        return ServerArtist(id: artist.id, name: artist.name, coverArt: artist.coverArt,
                            album: albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.map {
                                ServerAlbum(id: $0.id, name: $0.name, artist: $0.artist, artistId: $0.artistId, coverArt: $0.coverArt, year: $0.year, song: [])
                            })
    }
}
