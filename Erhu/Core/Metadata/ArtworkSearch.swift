import Foundation

/// One artwork found online, with where it came from.
struct ArtworkCandidate: Identifiable, Codable, Hashable, Sendable {
    let url: String
    let source: String
    var credit: ArtworkCredit? = nil
    var match: AlbumArtworkMatch? = nil
    var image: ArtworkImageFacts? = nil
    var recommended: Bool {
        guard let match, let image else { return false }
        return match.review.isEmpty && match.score >= 0.94 && min(image.width, image.height) >= 500
    }
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
    private let cache: ArtworkCandidateCache
    init(client: (any HTTPClient)? = nil, cache: ArtworkCandidateCache = .shared) {
        let client = client ?? ArtworkRequestClient.shared
        self.client = client
        self.commons = CommonsArtworkSearch(client: client)
        self.cache = cache
    }

    /// Preview and Apply use the same verified bytes, even if the source URL changes later.
    func imageData(_ candidate: ArtworkCandidate) async throws -> Data {
        if let bytes = await cache.data(for: candidate) { return bytes }
        guard let checked = await cache.validate(candidate, client: client),
              let bytes = await cache.data(for: checked) else { throw URLError(.cannotDecodeContentData) }
        return bytes
    }

    // MARK: Album covers

    /// Bounded search, edition-aware ranking and real image validation. No music is modified.
    func albumCovers(album: String, artist: String?, year: Int = 0) async -> [ArtworkCandidate] {
        let query = AlbumArtworkQuery(album: album, artist: artist ?? "", year: year)
        if let hit = await cache.load(query, freshOnly: true) { return hit }
        let results = await withTaskGroup(of: [ArtworkCandidate].self) { group in
            group.addTask { await self.albumResults(query) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(45)) } catch { return [] }
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        guard !Task.isCancelled else { return [] }
        if results.isEmpty { return await cache.load(query, freshOnly: false) ?? [] }
        await cache.save(results, query: query)
        return results
    }

    private func albumResults(_ query: AlbumArtworkQuery) async -> [ArtworkCandidate] {
        async let apple = iTunesAlbumCovers(query)
        async let archive = musicBrainzCovers(query)
        async let deezer = deezerAlbumCovers(query)
        var all = await archive + deezer + apple
        if all.isEmpty && !Task.isCancelled {
            all = await commons.search([query.artist, query.album, "album cover"].joined(separator: " "))
        }
        all.sort { ($0.match?.score ?? 0) > ($1.match?.score ?? 0) }
        var urls = Set<String>(), fingerprints = Set<String>(), valid: [ArtworkCandidate] = []
        for candidate in all.filter({ urls.insert($0.url).inserted }).prefix(10) {
            guard !Task.isCancelled else { return [] }
            guard let checked = await cache.validate(candidate, client: client), let facts = checked.image else { continue }
            // The same bytes on two services collapse only when the release metadata also agrees.
            let release = checked.match.map { AlbumArtworkMatching.normalize($0.album) + "|" + AlbumArtworkMatching.normalize($0.artist) + "|" + String($0.year) } ?? checked.url
            guard fingerprints.insert(release + "|" + facts.digest).inserted else { continue }
            valid.append(checked)
        }
        return valid.sorted {
            if $0.recommended != $1.recommended { return $0.recommended }
            if ($0.match?.score ?? 0) != ($1.match?.score ?? 0) { return ($0.match?.score ?? 0) > ($1.match?.score ?? 0) }
            let left = min($0.image?.width ?? 0, $0.image?.height ?? 0)
            let right = min($1.image?.width ?? 0, $1.image?.height ?? 0)
            return left == right ? $0.url < $1.url : left > right
        }
    }

    private func candidate(_ url: String?, source: String, query: AlbumArtworkQuery, album: String?, artist: String?, date: String? = nil, group: Bool = false) -> ArtworkCandidate? {
        guard let url, let album, let artist,
              let match = AlbumArtworkMatching.match(query, album: album, artist: artist, year: Int((date ?? "").prefix(4)) ?? 0, groupCover: group) else { return nil }
        return ArtworkCandidate(url: url, source: source, match: match)
    }

    private func iTunesAlbumCovers(_ query: AlbumArtworkQuery) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Result: Decodable { var artworkUrl100: String?; var artworkUrl60: String?; var collectionName: String?; var artistName: String?; var releaseDate: String? }
            var results: [Result]
        }
        let term = [query.artist, query.album].joined(separator: " ")
        guard let response = try? await fetchJSON(Response.self, requestURL("https://itunes.apple.com/search", [("term", term), ("entity", "album"), ("limit", "10")]), client: client) else { return [] }
        return response.results.compactMap { item in
            candidate((item.artworkUrl100 ?? item.artworkUrl60).map(ITunesProvider.upgradeArtwork), source: "iTunes", query: query, album: item.collectionName, artist: item.artistName, date: item.releaseDate)
        }
    }

    private func deezerAlbumCovers(_ query: AlbumArtworkQuery) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Artist: Decodable { var name: String? }
                var title: String?; var artist: Artist?; var releaseDate: String?; var coverXl: String?; var coverBig: String?
                enum CodingKeys: String, CodingKey { case title, artist; case releaseDate = "release_date", coverXl = "cover_xl", coverBig = "cover_big" }
            }
            var data: [Result]?
        }
        let term = "artist:\"\(query.artist)\" album:\"\(query.album)\""
        guard let response = try? await fetchJSON(Response.self, requestURL("https://api.deezer.com/search/album", [("q", term), ("limit", "10")]), client: client) else { return [] }
        return (response.data ?? []).compactMap {
            candidate($0.coverXl ?? $0.coverBig, source: "Deezer", query: query, album: $0.title, artist: $0.artist?.name, date: $0.releaseDate)
        }
    }

    private func musicBrainzCovers(_ query: AlbumArtworkQuery) async -> [ArtworkCandidate] {
        struct Credit: Decodable { var name: String? }
        struct Release: Decodable {
            var id: String; var title: String; var date: String?; var credits: [Credit]?
            enum CodingKeys: String, CodingKey { case id, title; case date; case credits = "artist-credit" }
        }
        struct Group: Decodable {
            var id: String; var title: String; var date: String?; var credits: [Credit]?
            enum CodingKeys: String, CodingKey { case id, title; case date = "first-release-date"; case credits = "artist-credit" }
        }
        struct Releases: Decodable { var releases: [Release]? }
        struct Groups: Decodable { var groups: [Group]?; enum CodingKeys: String, CodingKey { case groups = "release-groups" } }
        let terms = "release:\"\(escapePhrase(query.album))\"" + (artistSearchTerms(query.artist).map { " AND artist:(\($0))" } ?? "")
        let releases = try? await fetchJSON(Releases.self, requestURL("https://musicbrainz.org/ws/2/release", [("query", terms), ("fmt", "json"), ("limit", "5")]), client: client)
        var candidates = (releases?.releases ?? []).compactMap {
            candidate("https://coverartarchive.org/release/\($0.id)", source: "Cover Art Archive", query: query, album: $0.title, artist: $0.credits?.compactMap(\.name).joined(separator: " "), date: $0.date)
        }.sorted { ($0.match?.score ?? 0) > ($1.match?.score ?? 0) }
        var results: [ArtworkCandidate] = []
        for item in candidates.prefix(3) where !Task.isCancelled { results += await archiveImages(item) }
        if results.isEmpty && !Task.isCancelled {
            let groups = try? await fetchJSON(Groups.self, requestURL("https://musicbrainz.org/ws/2/release-group", [("query", terms), ("fmt", "json"), ("limit", "3")]), client: client)
            candidates = (groups?.groups ?? []).compactMap {
                candidate("https://coverartarchive.org/release-group/\($0.id)", source: "Cover Art Archive", query: query, album: $0.title, artist: $0.credits?.compactMap(\.name).joined(separator: " "), date: $0.date, group: true)
            }
            for item in candidates.prefix(2) where !Task.isCancelled { results += await archiveImages(item) }
        }
        return results
    }
    private func archiveImages(_ release: ArtworkCandidate) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Image: Decodable { var image: String; var front: Bool; var approved: Bool?; var thumbnails: [String: String]? }
            var images: [Image]
        }
        guard let url = URL(string: release.url), let response = try? await fetchJSON(Response.self, url, client: client) else { return [] }
        return response.images.filter { $0.front && $0.approved == true }.map { item in
            ArtworkCandidate(url: item.thumbnails?["1200"] ?? item.thumbnails?["large"] ?? item.image, source: release.source, match: release.match)
        }
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

    struct ArtistLinks: Sendable {
        let mbid: String
        let relations: [(type: String, resource: String)]
    }

    /// The MusicBrainz entries named exactly [name] (at most two) with their links.
    private func musicBrainzLinks(_ name: String) async -> [ArtistLinks] {
        struct ArtistSearch: Decodable {
            struct Artist: Decodable { var id: String; var name: String; var score: Int? }
            var artists: [Artist] = []
        }
        struct Relations: Decodable {
            struct Relation: Decodable {
                struct Target: Decodable { var resource: String }
                var type: String
                var url: Target?
            }
            var relations: [Relation]?
        }
        let query = "artist:\"\(escapePhrase(name.trimmed))\" OR alias:\"\(escapePhrase(name.trimmed))\""
        guard let search = try? await fetchJSON(ArtistSearch.self, requestURL("https://musicbrainz.org/ws/2/artist", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client)
        else { return [] }
        let exact = search.artists.filter { ($0.score ?? 0) >= 80 && Self.normalizeArtistName($0.name) == Self.normalizeArtistName(name) }
        var links: [ArtistLinks] = []
        for artist in exact.prefix(2) {
            guard !Task.isCancelled else { break }
            let relations = try? await fetchJSON(Relations.self, requestURL("https://musicbrainz.org/ws/2/artist/\(artist.id)", [("inc", "url-rels"), ("fmt", "json")]), client: client)
            let pairs = (relations?.relations ?? []).compactMap { relation in relation.url.map { (type: relation.type.lowercased(), resource: $0.resource) } }
            links.append(ArtistLinks(mbid: artist.id, relations: pairs))
        }
        return links
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
