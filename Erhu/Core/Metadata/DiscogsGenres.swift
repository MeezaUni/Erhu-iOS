import Foundation

struct DiscogsReference: Hashable, Sendable {
    let kind: String
    let id: Int64
    var key: String { "\(kind)/\(id)" }

    init?(_ address: String) {
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme ?? ""),
              ["discogs.com", "www.discogs.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let first = parts.first, ["release", "master"].contains(first), parts.count >= 2 else { return nil }
        let index = parts[1] == "view" ? 2 : 1
        guard parts.indices.contains(index), let id = Int64(parts[index].prefix(while: { $0.isNumber })), id > 0 else { return nil }
        self.kind = first == "release" ? "releases" : "masters"
        self.id = id
    }
}

/// Public release metadata only. Curated links and album/artist checks prevent title-only matches.
actor DiscogsGenres {
    private struct Release: Decodable {
        struct Artist: Decodable { var name: String }
        var id: Int64
        var title: String
        var artists: [Artist]?
        var genres: [String]?
        var styles: [String]?
    }
    private let client: HTTPClient
    private var cache: [String: Release] = [:]
    private var retryAt = Date.distantPast
    init(client: HTTPClient) { self.client = client }

    func genres(_ ref: DiscogsReference, album: String, artist: String) async throws -> [String] {
        let release: Release
        if let cached = cache[ref.key] { release = cached }
        else {
            guard Date() >= retryAt else { return [] }
            let (data, response) = try await client.get(URL(string: "https://api.discogs.com/\(ref.key)")!, headers: ["User-Agent": metadataUserAgent])
            if response.statusCode == 429 || response.statusCode == 403 {
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
                retryAt = Date().addingTimeInterval(max(60, delay))
            }
            try checkStatus(response)
            release = try JSONDecoder().decode(Release.self, from: data)
            guard release.id == ref.id else { return [] }
            if cache.count >= 500 { cache.removeAll() }
            cache[ref.key] = release
        }
        let artists = (release.artists ?? []).map {
            $0.name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        }.joined(separator: " & ")
        guard MetadataEnrichment.releaseKey(release.title) == MetadataEnrichment.releaseKey(album),
              !artists.isBlank, creditSimilarity(artists, artist) >= 0.8 else { return [] }
        return Genres.normalize(((release.styles ?? []) + (release.genres ?? [])).map(Optional.init))
    }
}
