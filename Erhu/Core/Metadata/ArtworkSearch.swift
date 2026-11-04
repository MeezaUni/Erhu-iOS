import Foundation

/// One artwork found online, with where it came from.
struct ArtworkCandidate: Identifiable, Hashable, Sendable {
    let url: String
    let source: String
    var credit: ArtworkCredit? = nil
    var id: String { url }
}

/// How [ArtworkSearch.selectDeezerArtist] decided.
enum DeezerArtistMatch: Equatable {
    case selected(artistId: Int64, pictureUrl: String)
    case rejected(String)
}

/// A Deezer artist profile as the search returns it.
struct DeezerArtist: Decodable, Equatable, Sendable {
    var id: Int64
    var name: String
    var pictureMedium: String?
    var pictureBig: String?
    var pictureXl: String?
    /// Followers on Deezer; used only to tell apart profiles that share one exact name.
    var nbFan: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case pictureMedium = "picture_medium"
        case pictureBig = "picture_big"
        case pictureXl = "picture_xl"
        case nbFan = "nb_fan"
    }

    init(id: Int64, name: String, pictureMedium: String? = nil, pictureBig: String? = nil, pictureXl: String? = nil, nbFan: Int64 = 0) {
        self.id = id
        self.name = name
        self.pictureMedium = pictureMedium
        self.pictureBig = pictureBig
        self.pictureXl = pictureXl
        self.nbFan = nbFan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pictureMedium = try c.decodeIfPresent(String.self, forKey: .pictureMedium)
        pictureBig = try c.decodeIfPresent(String.self, forKey: .pictureBig)
        pictureXl = try c.decodeIfPresent(String.self, forKey: .pictureXl)
        nbFan = try c.decodeIfPresent(Int64.self, forKey: .nbFan) ?? 0
    }
}

/// Keyless catalogue artwork plus licence-checked Wikimedia Commons fallbacks.
struct ArtworkSearch: Sendable {
    let client: HTTPClient
    private let commons: CommonsArtworkSearch
    init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
        self.commons = CommonsArtworkSearch(client: client)
    }

    // MARK: Album covers

    /// Covers for an album from every source, best sources first, each image once.
    func albumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        async let iTunes = iTunesAlbumCovers(album: album, artist: artist)
        async let groups = releaseGroups(album: album, artist: artist)
        async let deezer = deezerAlbumCovers(album: album, artist: artist)
        let groupIds = await groups
        let archive = await archiveAlbumCovers(groupIds)
        let primary = await iTunes + archive + deezer
        let all: [ArtworkCandidate]
        if primary.isEmpty { all = await commons.search([artist, album, "album cover"].compactMap { $0 }.joined(separator: " ")) }
        else { all = primary }
        var seen = Set<String>()
        return all.filter { seen.insert($0.url).inserted }
    }

    private func archiveAlbumCovers(_ groupIds: [String]) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Cover: Decodable { var image: String; var front: Bool; var thumbnails: [String: String]? }
            var images: [Cover]
        }
        var results: [ArtworkCandidate] = []
        for id in groupIds.prefix(3) {
            guard let response = try? await fetchJSON(Response.self, URL(string: "https://coverartarchive.org/release-group/\(id)")!, client: client) else { continue }
            results += response.images.filter(\.front).map { image in
                ArtworkCandidate(url: image.thumbnails?["1200"] ?? image.thumbnails?["large"] ?? image.image, source: "Cover Art Archive")
            }
        }
        return results
    }

    private func iTunesAlbumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Result: Decodable { var artworkUrl100: String?; var artworkUrl60: String? }
            var results: [Result] = []
        }
        let usableArtist = artist.flatMap { isUsableTag($0) ? $0 : nil }
        let term = [usableArtist, album].compactMap { $0 }.joined(separator: " ")
        guard !term.isBlank else { return [] }
        let response = try? await fetchJSON(Response.self, requestURL("https://itunes.apple.com/search", [("term", term), ("entity", "album"), ("limit", "10")]), client: client)
        return (response?.results ?? []).compactMap { ($0.artworkUrl100 ?? $0.artworkUrl60).map { ArtworkCandidate(url: ITunesProvider.upgradeArtwork($0), source: "iTunes") } }
    }

    /// MusicBrainz release groups for an album (their covers live in the Cover Art Archive).
    private func releaseGroups(album: String, artist: String?) async -> [String] {
        struct Response: Decodable {
            struct Group: Decodable { var id: String }
            var groups: [Group] = []
            enum CodingKeys: String, CodingKey { case groups = "release-groups" }
        }
        var query = "release:\"\(escapePhrase(album.trimmed))\""
        if let terms = artistSearchTerms(artist.flatMap { isUsableTag($0) ? $0 : nil }) { query += " AND artist:(\(terms))" }
        let response = try? await fetchJSON(Response.self, requestURL("https://musicbrainz.org/ws/2/release-group", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client)
        return (response?.groups ?? []).map(\.id)
    }

    private func deezerAlbumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Album: Decodable {
                var coverXl: String?
                var coverBig: String?
                enum CodingKeys: String, CodingKey { case coverXl = "cover_xl", coverBig = "cover_big" }
            }
            var data: [Album]?
        }
        let usableArtist = artist.flatMap { isUsableTag($0) ? $0 : nil }
        let query = usableArtist.map { "artist:\"\($0)\" album:\"\(album)\"" } ?? album
        let response = try? await fetchJSON(Response.self, requestURL("https://api.deezer.com/search/album", [("q", query)]), client: client)
        return (response?.data ?? []).compactMap { ($0.coverXl ?? $0.coverBig).map { ArtworkCandidate(url: $0, source: "Deezer") } }
    }

    // MARK: Artist photos

    /// Photos of an artist: Deezer profiles with exactly this name (most followed first, real photos
    /// only), then licence-checked Wikimedia Commons through the artist's MusicBrainz links.
    func artistPhotos(_ name: String) async -> [ArtworkCandidate] {
        guard isUsableTag(name) else { return [] }
        async let deezer = deezerArtistPhotos(name)
        async let links = musicBrainzLinks(name)
        let found = await links
        let wiki = await wikimediaPhotos(name, links: found)
        let all = await deezer + wiki
        var seen = Set<String>()
        return all.filter { seen.insert($0.url).inserted }
    }

    func deezerArtists(_ name: String) async throws -> [DeezerArtist] {
        struct Response: Decodable {
            var data: [DeezerArtist]?
            var error: DeezerProvider.DeezerError?
        }
        // The plain name, not artist:"…": Deezer ranks the field query so that the exact artist is often missing.
        let response = try await fetchJSON(Response.self, requestURL("https://api.deezer.com/search/artist", [("q", name.trimmed), ("limit", "100")]), client: client)
        if let error = response.error { throw ProviderError(status: .failed, message: "Deezer: \(error.message ?? "artist search failed")") }
        guard let data = response.data else { throw ProviderError(status: .failed, message: "Deezer gave no results field") }
        return data
    }

    private func deezerArtistPhotos(_ name: String) async -> [ArtworkCandidate] {
        guard let artists = try? await deezerArtists(name) else { return [] }
        let key = Self.normalizeArtistName(name)
        let exact = artists.filter { Self.normalizeArtistName($0.name) == key }.sorted { $0.nbFan > $1.nbFan }
        return (exact.isEmpty ? artists : exact).compactMap(Self.realPicture).map { ArtworkCandidate(url: $0, source: "Deezer") }
    }

    /// Resolve MusicBrainz-linked Wikidata portraits through Commons imageinfo, retaining
    /// only images with usable free-licence metadata. Non-free Wikipedia thumbnails are omitted.
    private func wikimediaPhotos(_ name: String, links: [ArtistLinks]) async -> [ArtworkCandidate] {
        var files: [String] = []
        for relation in links.flatMap(\.relations) where relation.type == "wikidata" {
            let qid = relation.resource.components(separatedBy: "/").last ?? ""
            guard qid.uppercased().hasPrefix("Q") else { continue }
            files += await wikidataPortraits(qid)
        }
        let linked = await commons.files(files)
        return linked.isEmpty ? await commons.search(name + " musician") : linked
    }

    private func wikidataPortraits(_ qid: String) async -> [String] {
        guard let url = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json"),
              let answer = try? await client.get(url, headers: ["User-Agent": metadataUserAgent]), (200..<300).contains(answer.1.statusCode),
              let object = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any],
              let entity = (object["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = (entity["claims"] as? [String: Any])?["P18"] as? [[String: Any]] else { return [] }
        return claims.prefix(4).compactMap { claim in
            ((claim["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? String
        }
    }

    static func normalizeImageUrl(_ url: String) -> String {
        let trimmed = url.trimmed
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") { return "https://" + trimmed.dropFirst(7) }
        return trimmed
    }

    // MARK: Automatic artist photos

    /// The top same-name profile needs this many times the fans of the next one.
    static let dominanceFactor: Int64 = 10

    /// Picks the Deezer profile that is safely [artistName], or rejects all of them: only profiles
    /// with exactly this name count; of several, the top one needs ten times the fans of the next;
    /// and it must have a real photo (never a fallback to a smaller duplicate). A wrong photo is
    /// worse than none.
    static func selectDeezerArtist(_ artistName: String, _ candidates: [DeezerArtist]) -> DeezerArtistMatch {
        let key = normalizeArtistName(artistName)
        let exact = candidates.filter { normalizeArtistName($0.name) == key }.enumerated()
            .sorted { $0.element.nbFan != $1.element.nbFan ? $0.element.nbFan > $1.element.nbFan : $0.offset < $1.offset }.map(\.element)
        guard let top = exact.first else { return .rejected("no exact-name profile") }
        if exact.count > 1, top.nbFan < dominanceFactor * max(exact[1].nbFan, 1) {
            return .rejected("ambiguous: \(exact.count) exact-name profiles, \(top.nbFan) vs \(exact[1].nbFan) fans")
        }
        guard let picture = realPicture(top) else { return .rejected("profile \(top.id) has no photo") }
        return .selected(artistId: top.id, pictureUrl: picture)
    }

    /// Harmless spelling differences only: NFKC, case, curly quotes, whitespace. "$ & , ." are kept,
    /// so "A$AP Rocky" and "Tyler, The Creator" stay distinct.
    static func normalizeArtistName(_ name: String) -> String {
        let quotes: [Character: Character] = ["\u{2018}": "'", "\u{2019}": "'", "\u{201B}": "'", "\u{02BC}": "'", "\u{2032}": "'",
                                              "\u{201C}": "\"", "\u{201D}": "\"", "\u{201F}": "\"", "\u{2033}": "\""]
        let straight = String(name.precomposedStringWithCompatibilityMapping.map { quotes[$0] ?? $0 })
        // Upper then lower case folds more than lowercasing alone (e.g. "ß" and "SS").
        return Regex16("\\s+").replacing(in: straight.uppercased().lowercased().trimmed, with: " ")
    }

    /// Deezer returns ".../images/artist//..." (no image hash) for a profile without a photo.
    static func realPicture(_ artist: DeezerArtist) -> String? {
        guard let url = [artist.pictureBig, artist.pictureXl, artist.pictureMedium].compactMap({ $0 }).first(where: { !$0.isBlank }),
              !url.contains("/artist//") else { return nil }
        return url
    }
}
