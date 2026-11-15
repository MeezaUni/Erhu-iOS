import CryptoKit
import Foundation

/// A music server the listener added: Erhu Server (Navidrome) or another Subsonic-compatible
/// server. The password is kept in the Keychain, never here.
struct ServerAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// The server's address without the API path, e.g. http://192.168.1.20:4533
    var baseURL: URL
    var username: String

    /// Turns what the listener typed into a server address: adds http:// when no scheme is
    /// given, drops trailing slashes and a pasted web-app path ("/app", "/rest").
    /// A base path (a server behind a reverse proxy at /music) is kept.
    static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            guard !lower.contains("://") else { return nil }   // another scheme, such as ftp://
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/app", "/rest"] where path.lowercased().hasSuffix(suffix) { path.removeLast(suffix.count) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }
}

enum SubsonicError: LocalizedError, Equatable {
    case invalidAddress
    case missingPassword
    case http(Int)
    case server(code: Int, message: String?)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            String(localized: "That server address doesn't look right. Use the address shown by Erhu Server, for example http://192.168.1.20:4533.")
        case .missingPassword:
            String(localized: "The password for this server is missing. Remove the server and add it again.")
        case .http(let status):
            String(localized: "The server answered with an error (HTTP \(status)). Check the address.")
        case .server(let code, let message):
            switch code {
            case 40: String(localized: "Wrong username or password.")
            case 50: String(localized: "This account isn't allowed to do that on the server.")
            case 70: String(localized: "The server couldn't find that item. It may have been removed.")
            default: message ?? String(localized: "The server reported an error (code \(code)).")
            }
        case .unreadableResponse:
            String(localized: "That address answered, but not like a music server. Check the address and port.")
        }
    }
}

/// How streamed songs are fetched: the original file, or a smaller copy the server converts.
enum StreamQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, mp3_320, mp3_192, mp3_128
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: String(localized: "Original file")
        case .mp3_320: String(localized: "MP3 320 kbps")
        case .mp3_192: String(localized: "MP3 192 kbps")
        case .mp3_128: String(localized: "MP3 128 kbps")
        }
    }

    /// The stream request's format and maximum bit rate (nil: the server's original file).
    var transcoding: (format: String, maxBitRate: Int)? {
        switch self {
        case .original: nil
        case .mp3_320: ("mp3", 320)
        case .mp3_192: ("mp3", 192)
        case .mp3_128: ("mp3", 128)
        }
    }
}

/// Talks to one server with the Subsonic API: token authentication (a fresh salt per request, so
/// the password itself is never sent), JSON responses, URLs for streaming, downloads and covers.
struct SubsonicClient: Sendable {
    static let apiVersion = "1.16.1"
    static let clientName = "Erhu"

    let account: ServerAccount
    let password: String
    var session: URLSession = .shared
    /// One salt for this client's media URLs, so a cover's URL stays the same between redraws and
    /// image caches work. API calls still use a fresh salt each time.
    var mediaSalt = SubsonicClient.makeSalt()

    /// md5(password + salt) as lower-case hex: the Subsonic token.
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func makeSalt() -> String {
        (0..<12).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }

    /// The URL of API method [method] with [items], authenticated.
    func url(_ method: String, _ items: [URLQueryItem] = [], salt: String = SubsonicClient.makeSalt(), json: Bool = true) -> URL {
        var components = URLComponents(url: account.baseURL.appendingPathComponent("rest").appendingPathComponent(method),
                                       resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: Self.token(password: password, salt: salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
        ]
        if json { query.append(URLQueryItem(name: "f", value: "json")) }
        components.queryItems = query + items
        return components.url!
    }

    /// Calls [method] and returns the response, or throws the server's error.
    func call(_ method: String, _ items: [URLQueryItem] = []) async throws -> SubsonicResponse {
        var request = URLRequest(url: url(method, items))
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return try Self.decode(data, response: response)
    }

    static func decode(_ data: Data, response: URLResponse?) throws -> SubsonicResponse {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Some servers return a Subsonic error body with a non-2xx status; prefer its message.
            if let body = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data).response, let error = body.error {
                throw SubsonicError.server(code: error.code, message: error.message)
            }
            throw SubsonicError.http(http.statusCode)
        }
        guard let body = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data).response else {
            throw SubsonicError.unreadableResponse
        }
        if !body.isOK { throw SubsonicError.server(code: body.error?.code ?? 0, message: body.error?.message) }
        return body
    }

    // MARK: Methods

    func ping() async throws -> SubsonicResponse { try await call("ping") }

    func artists() async throws -> [ServerArtist] {
        try await call("getArtists").artists?.allArtists ?? []
    }

    func artist(_ id: String) async throws -> ServerArtist {
        guard let artist = try await call("getArtist", [URLQueryItem(name: "id", value: id)]).artist else { throw SubsonicError.unreadableResponse }
        return artist
    }

    /// [type]: newest, recent, frequent, random, alphabeticalByName, starred.
    func albumList(_ type: String, size: Int = 60, offset: Int = 0) async throws -> [ServerAlbum] {
        try await call("getAlbumList2", [URLQueryItem(name: "type", value: type), URLQueryItem(name: "size", value: String(size)),
                                         URLQueryItem(name: "offset", value: String(offset))]).albumList2?.album ?? []
    }

    func album(_ id: String) async throws -> ServerAlbum {
        guard let album = try await call("getAlbum", [URLQueryItem(name: "id", value: id)]).album else { throw SubsonicError.unreadableResponse }
        return album
    }

    func search(_ query: String) async throws -> SubsonicSearchResult? {
        try await call("search3", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "artistCount", value: "10"),
                                   URLQueryItem(name: "albumCount", value: "20"), URLQueryItem(name: "songCount", value: "40")]).searchResult3
    }

    func playlists() async throws -> [ServerPlaylist] {
        try await call("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(_ id: String) async throws -> ServerPlaylist {
        guard let playlist = try await call("getPlaylist", [URLQueryItem(name: "id", value: id)]).playlist else { throw SubsonicError.unreadableResponse }
        return playlist
    }

    /// Tells the server a song was played, so its play counts (and Last.fm, if linked there) stay right.
    func scrobble(_ id: String) async throws {
        _ = try await call("scrobble", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "submission", value: "true")])
    }

    // MARK: Media URLs

    /// The song as Erhu streams it: the original file, or converted to [quality].
    func streamURL(_ id: String, quality: StreamQuality) -> URL {
        var items = [URLQueryItem(name: "id", value: id)]
        if let transcoding = quality.transcoding {
            items += [URLQueryItem(name: "format", value: transcoding.format),
                      URLQueryItem(name: "maxBitRate", value: String(transcoding.maxBitRate))]
        } else {
            items.append(URLQueryItem(name: "format", value: "raw"))
        }
        return url("stream", items, salt: mediaSalt, json: false)
    }

    /// The original file, unchanged, for saving to the device.
    func downloadURL(_ id: String) -> URL { url("download", [URLQueryItem(name: "id", value: id)], salt: mediaSalt, json: false) }

    func coverArtURL(_ id: String, size: Int = 600) -> URL {
        url("getCoverArt", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: String(size))], salt: mediaSalt, json: false)
    }
}
