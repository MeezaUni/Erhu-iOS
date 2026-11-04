import CryptoKit
import Foundation
import ImageIO

/// Streaming limits apply before buffering entire provider responses or images.
struct ArtworkHTTPClient: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let limit = headers["Accept"] == "application/json" ? 2 * 1024 * 1024 : 3 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, http)
    }
}

/// Shared artwork request pacing, including concurrent searches and artist-photo lookups.
actor ArtworkRequestClient: HTTPClient {
    static let shared = ArtworkRequestClient(base: ArtworkHTTPClient())
    private let base: any HTTPClient
    private var next: [String: Date] = [:]
    init(base: any HTTPClient) { self.base = base }
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let host = url.host ?? ""
        while let time = next[host], time > Date() {
            try await Task.sleep(for: .seconds(min(time.timeIntervalSinceNow, 60)))
            try Task.checkCancellation()
        }
        next[host] = Date().addingTimeInterval(host == "musicbrainz.org" ? 1.1 : 0.25)
        let answer = try await base.get(url, headers: headers)
        if [429, 503].contains(answer.1.statusCode) {
            let requested = answer.1.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 30
            next[host] = Date().addingTimeInterval(min(120, max(1, requested)))
        }
        return answer
    }
}

struct ArtworkImageFacts: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let digest: String
    var resolution: String { "\(width) × \(height)" }

    static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func inspect(_ data: Data) -> ArtworkImageFacts? {
        guard !data.isEmpty, data.count <= 3 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 64, height >= 64, width <= 12000, height <= 12000,
              width * height <= 40_000_000,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) != nil else { return nil }
        return ArtworkImageFacts(width: width, height: height, digest: ArtworkCandidateCache.key(data))
    }
}

/// Disposable cache; embedded artwork and custom images are never stored or evicted here.
actor ArtworkCandidateCache {
    static let shared = ArtworkCandidateCache()
    static let maxBytes = 64 * 1024 * 1024
    private let root: URL
    private let budget: Int
    private struct Record: Codable { let query: AlbumArtworkQuery; let date: Date; let candidates: [ArtworkCandidate] }
    init(root: URL = LibraryPaths.cachesFolder.appendingPathComponent("artwork-search-v1"), budget: Int = ArtworkCandidateCache.maxBytes) {
        self.root = root; self.budget = budget
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    nonisolated static func key(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func imageURL(_ candidate: ArtworkCandidate) -> URL { root.appendingPathComponent(Self.key(Data(candidate.url.utf8)) + ".image") }
    private func queryURL(_ query: AlbumArtworkQuery) -> URL {
        let text = "\(query.album)\n\(query.artist)\n\(query.year)"
        return root.appendingPathComponent(Self.key(Data(text.utf8)) + ".json")
    }
    func data(for candidate: ArtworkCandidate) -> Data? {
        let file = imageURL(candidate)
        guard let bytes = try? Data(contentsOf: file), let facts = ArtworkImageFacts.inspect(bytes),
              candidate.image == nil || candidate.image == facts else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return bytes
    }
    func validate(_ candidate: ArtworkCandidate, client: any HTTPClient) async -> ArtworkCandidate? {
        if let bytes = data(for: candidate), let facts = ArtworkImageFacts.inspect(bytes) {
            var result = candidate; result.image = facts; return result
        }
        guard let url = URL(string: candidate.url), url.scheme == "https", !Task.isCancelled,
              let (bytes, response) = try? await client.get(url, headers: ["User-Agent": metadataUserAgent]),
              response.statusCode == 200, !Task.isCancelled,
              let facts = ArtworkImageFacts.inspect(bytes) else { return nil }
        // An already-previewed candidate must never silently become a different image.
        guard candidate.image == nil || candidate.image == facts else { return nil }
        do { try bytes.write(to: imageURL(candidate), options: .atomic) } catch { return nil }
        trim()
        var result = candidate; result.image = facts; return result
    }
    func load(_ query: AlbumArtworkQuery, freshOnly: Bool) -> [ArtworkCandidate]? {
        guard let bytes = try? Data(contentsOf: queryURL(query)),
              let record = try? JSONDecoder().decode(Record.self, from: bytes), record.query == query,
              !freshOnly || Date().timeIntervalSince(record.date) < 7 * 86400 else { return nil }
        let available = record.candidates.filter { data(for: $0) != nil }
        return available.isEmpty ? nil : available
    }
    func save(_ candidates: [ArtworkCandidate], query: AlbumArtworkQuery) {
        guard !candidates.isEmpty, let bytes = try? JSONEncoder().encode(Record(query: query, date: Date(), candidates: candidates)) else { return }
        try? bytes.write(to: queryURL(query), options: .atomic)
        trim()
    }
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        let rows = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = rows.reduce(0) { $0 + $1.1 }, queries = rows.filter { $0.0.pathExtension == "json" }.count
        for (url, bytes, _) in rows where total > budget || queries > 256 {
            if total <= budget && url.pathExtension != "json" { continue }
            try? FileManager.default.removeItem(at: url); total -= bytes
            if url.pathExtension == "json" { queries -= 1 }
        }
    }
}
