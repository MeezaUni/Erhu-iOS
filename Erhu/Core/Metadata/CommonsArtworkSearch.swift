import Foundation
import Observation

struct ArtworkCredit: Codable, Hashable, Sendable, Identifiable {
    let title: String
    let author: String
    let license: String
    let page: URL
    let licenseURL: URL?
    var id: String { page.absoluteString }
}

/// A keyless Commons fallback. Only images with recognizable free-licence metadata are
/// offered; search-engine results and Wikipedia fair-use images are not scraped/imported.
actor CommonsArtworkSearch {
    private let client: any HTTPClient
    private var nextRequest = Date.distantPast
    private var cache: [String: (Date, [ArtworkCandidate])] = [:]
    init(client: any HTTPClient) { self.client = client }

    func search(_ query: String) async -> [ArtworkCandidate] {
        await request([("generator", "search"), ("gsrnamespace", "6"), ("gsrlimit", "8"), ("gsrsearch", query + " filemime:bitmap")])
    }
    func files(_ names: [String]) async -> [ArtworkCandidate] {
        guard !names.isEmpty else { return [] }
        return await request([("titles", names.prefix(4).map { $0.hasPrefix("File:") ? $0 : "File:" + $0 }.joined(separator: "|"))])
    }
    private func request(_ terms: [(String, String)]) async -> [ArtworkCandidate] {
        let items = [("action", "query"), ("format", "json"), ("prop", "imageinfo"), ("iiprop", "url|extmetadata|mime"),
                     ("iiurlwidth", "1200"), ("maxage", "300")] + terms
        let url = requestURL("https://commons.wikimedia.org/w/api.php", items)
        let key = url.absoluteString
        if let hit = cache[key], Date().timeIntervalSince(hit.0) < 3600 { return hit.1 }
        do {
            while nextRequest > Date() {
                try await Task.sleep(for: .seconds(min(nextRequest.timeIntervalSinceNow, 60)))
                try Task.checkCancellation()
            }
            nextRequest = Date().addingTimeInterval(1.1)
            let (data, response) = try await client.get(url, headers: ["User-Agent": metadataUserAgent])
            if response.statusCode == 429 {
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
                nextRequest = Date().addingTimeInterval(max(delay, 1)); return []
            }
            guard response.statusCode == 200 else { return [] }
            let results = Self.candidates(data)
            if cache.count >= 64 { cache = cache.filter { Date().timeIntervalSince($0.value.0) < 3600 }; if cache.count >= 64 { cache.removeAll() } }
            cache[key] = (Date(), results)
            return results
        } catch { return [] }
    }

    static func candidates(_ data: Data) -> [ArtworkCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return [] }
        return pages.values.sorted { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }.compactMap { page in
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, ["image/jpeg", "image/png", "image/webp"].contains(mime),
                  let address = (info["thumburl"] ?? info["url"]) as? String, let image = URL(string: address),
                  image.scheme == "https", image.host == "upload.wikimedia.org",
                  let pageAddress = info["descriptionurl"] as? String, let source = URL(string: pageAddress),
                  source.scheme == "https", source.host == "commons.wikimedia.org", source.path.hasPrefix("/wiki/File:"),
                  let metadata = info["extmetadata"] as? [String: [String: Any]] else { return nil }
            func value(_ name: String) -> String { plain(metadata[name]?["value"] as? String ?? "") }
            let license = value("LicenseShortName")
            let rawLicenseURL = (metadata["LicenseUrl"]?["value"] as? String ?? "").replacingOccurrences(of: "http://", with: "https://")
            let licenseURL = URL(string: rawLicenseURL)
            let cc = licenseURL?.scheme == "https" && licenseURL?.host == "creativecommons.org"
            let path = licenseURL?.path ?? ""
            let by = cc && (path.hasPrefix("/licenses/by/") || path.hasPrefix("/licenses/by-sa/")) && license.hasPrefix("CC BY")
            let cc0 = cc && path.hasPrefix("/publicdomain/zero/")
            let publicDomain = license.lowercased() == "public domain" && value("Copyrighted").lowercased() == "false"
            let author = value("Artist").nonBlank ?? value("Attribution").nonBlank
            guard by || cc0 || publicDomain, !by || author != nil else { return nil }
            let credit = ArtworkCredit(title: plain(page["title"] as? String ?? "Commons image"), author: author ?? "Not stated",
                                       license: license.isEmpty ? "CC0" : license, page: source,
                                       licenseURL: cc ? licenseURL : nil)
            return ArtworkCandidate(url: image.absoluteString, source: "Wikimedia Commons", credit: credit)
        }
    }

    static func plain(_ html: String) -> String {
        var text = Regex16("<[^>]*>").replacing(in: html, with: " ")
        for (encoded, decoded) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")] { text = text.replacingOccurrences(of: encoded, with: decoded) }
        return String(Regex16("\\s+").replacing(in: text, with: " ").trimmed.prefix(1000))
    }
}

/// Keep creator/source/licence information locally before applying a Commons image.
@MainActor @Observable final class ArtworkCredits {
    static let shared = ArtworkCredits()
    private(set) var records: [String: ArtworkCredit] = [:]
    private let file: URL
    init(file: URL = LibraryPaths.supportFolder.appending(path: "artwork-credits.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: ArtworkCredit].self, from: data) { records = saved }
    }
    func remember(_ credit: ArtworkCredit) throws {
        var updated = records; updated[credit.id] = credit
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        records = updated
    }
}
