import Foundation

// The parts of the Subsonic / OpenSubsonic API that Erhu uses, as returned with `f=json` by
// Navidrome (the server Erhu Server is built on) and other compatible servers. Every field a
// server may leave out is optional. IDs are strings: Navidrome uses opaque IDs, older servers
// use numbers, and both arrive as JSON strings.

/// The `subsonic-response` object. Only the payload of the called method is present.
struct SubsonicResponse: Decodable, Sendable {
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: SubsonicErrorBody?
    let artists: SubsonicArtistsIndex?
    let artist: ServerArtist?
    let album: ServerAlbum?
    let albumList2: SubsonicAlbumList?
    let searchResult3: SubsonicSearchResult?
    let playlists: SubsonicPlaylists?
    let playlist: ServerPlaylist?
    /// getStarred2: the account's favourite artists, albums and songs.
    let starred2: SubsonicSearchResult?

    var isOK: Bool { status == "ok" }
}

/// Wrapper with the key the server uses for the response object.
struct SubsonicEnvelope: Decodable, Sendable {
    let response: SubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicErrorBody: Decodable, Sendable, Hashable {
    let code: Int
    let message: String?
}

struct SubsonicArtistsIndex: Decodable, Sendable {
    let index: [Group]

    struct Group: Decodable, Sendable {
        let name: String
        let artist: [ServerArtist]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            artist = try c.decodeList(ServerArtist.self, forKey: .artist)
        }
        enum CodingKeys: String, CodingKey { case name, artist }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeList(Group.self, forKey: .index)
    }
    enum CodingKeys: String, CodingKey { case index }

    /// Every artist, in the server's order.
    var allArtists: [ServerArtist] { index.flatMap(\.artist) }
}

struct ServerArtist: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let album: [ServerAlbum]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        albumCount = try c.decodeIfPresent(Int.self, forKey: .albumCount)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        album = try c.decodeList(ServerAlbum.self, forKey: .album)
    }
    enum CodingKeys: String, CodingKey { case id, name, albumCount, coverArt, album }
}

struct ServerAlbum: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let song: [ServerSong]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id)
        // getAlbum and getAlbumList2 use "name"; some servers use "title".
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeFlexibleStringIfPresent(forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        song = try c.decodeList(ServerSong.self, forKey: .song)
    }
    enum CodingKeys: String, CodingKey { case id, name, title, artist, artistId, coverArt, songCount, duration, year, genre, song }
}

struct ServerSong: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let albumId: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    /// The original file's extension ("mp3", "flac").
    let suffix: String?
    /// Seconds.
    let duration: Int?
    let bitRate: Int?
    let bpm: Int?
    let isVideo: Bool?
    /// When the account marked the song as a favourite (nil: not a favourite).
    let starred: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        albumId = try c.decodeFlexibleStringIfPresent(forKey: .albumId)
        artistId = try c.decodeFlexibleStringIfPresent(forKey: .artistId)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        bpm = try c.decodeIfPresent(Int.self, forKey: .bpm)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo)
        starred = try c.decodeIfPresent(String.self, forKey: .starred)
    }
    enum CodingKeys: String, CodingKey {
        case id, title, album, artist, albumId, artistId, track, discNumber, year, genre, coverArt, size, contentType, suffix, duration, bitRate, bpm, isVideo, starred
    }

    /// The original file extension, lower-cased, or "mp3" if the server didn't say.
    var fileExtension: String {
        let raw = (suffix ?? "").lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return raw.isEmpty ? "mp3" : raw
    }
}

struct SubsonicAlbumList: Decodable, Sendable {
    let album: [ServerAlbum]
    init(from decoder: Decoder) throws {
        album = try decoder.container(keyedBy: CodingKeys.self).decodeList(ServerAlbum.self, forKey: .album)
    }
    enum CodingKeys: String, CodingKey { case album }
}

struct SubsonicSearchResult: Decodable, Sendable {
    let artist: [ServerArtist]
    let album: [ServerAlbum]
    let song: [ServerSong]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decodeList(ServerArtist.self, forKey: .artist)
        album = try c.decodeList(ServerAlbum.self, forKey: .album)
        song = try c.decodeList(ServerSong.self, forKey: .song)
    }
    enum CodingKeys: String, CodingKey { case artist, album, song }
}

struct SubsonicPlaylists: Decodable, Sendable {
    let playlist: [ServerPlaylist]
    init(from decoder: Decoder) throws {
        playlist = try decoder.container(keyedBy: CodingKeys.self).decodeList(ServerPlaylist.self, forKey: .playlist)
    }
    enum CodingKeys: String, CodingKey { case playlist }
}

struct ServerPlaylist: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let songCount: Int?
    let duration: Int?
    let owner: String?
    let coverArt: String?
    let entry: [ServerSong]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        entry = try c.decodeList(ServerSong.self, forKey: .entry)
    }
    enum CodingKeys: String, CodingKey { case id, name, songCount, duration, owner, coverArt, entry }
}

extension KeyedDecodingContainer {
    /// A list that some servers send as a single object when it has one element, or leave out
    /// when it is empty.
    func decodeList<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        if let many = try? decode([T].self, forKey: key) { return many }
        return [try decode(T.self, forKey: key)]
    }

    /// An ID that may arrive as a string or a number.
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let text = try? decode(String.self, forKey: key) { return text }
        return String(try decode(Int64.self, forKey: key))
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFlexibleString(forKey: key)
    }
}
