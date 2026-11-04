import Foundation

/// Local tags describe the wanted release; alternate editions always need a human decision.
struct AlbumArtworkQuery: Codable, Hashable, Sendable {
    let album: String
    let artist: String
    var year: Int = 0
}

struct AlbumArtworkMatch: Codable, Hashable, Sendable {
    let album: String
    let artist: String
    var year: Int = 0
    var review: [String] = []
    var score: Double = 0
}

/// Inspired by the edition-aware Android artwork matcher. This never applies an image.
enum AlbumArtworkMatching {
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return Regex16("[^\\p{L}\\p{N}]+").replacing(in: folded, with: " ").trimmed
    }
    private static let editions = "deluxe|remaster(?:ed)?|anniversary|expanded|bonus|live|remix|mono|stereo|explicit|clean|collector|promo(?:tional)?|quadraphonic|box set"
    static func edition(_ title: String) -> Set<String> {
        let normal = normalize(title)
        let markers = Regex16("\\b(?:" + editions + ")\\b").matches(in: normal).map { $0.group(0, in: normal) }
        guard !markers.isEmpty else { return [] }
        let years = Regex16("\\b(?:19|20)[0-9]{2}\\b").matches(in: normal).map { $0.group(0, in: normal) }
        return Set(markers.map { $0.hasPrefix("remaster") ? "remaster" : $0 }).union(years)
    }
    static func base(_ title: String) -> String {
        var text = title.lowercased()
        text = Regex16("\\([^)]*(?:" + editions + ")[^)]*\\)").replacing(in: text, with: " ")
        text = Regex16("\\[[^\\]]*(?:" + editions + ")[^\\]]*\\]").replacing(in: text, with: " ")
        text = Regex16("\\s*[-–:]\\s*(?:" + editions + ").*$").replacing(in: text, with: " ")
        text = Regex16("\\s*[-–]\\s*(?:single|ep)$").replacing(in: text, with: " ")
        return normalize(text)
    }
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let left = Set(a.split(separator: " ")), right = Set(b.split(separator: " "))
        let overlap = Double(left.intersection(right).count) / Double(max(left.count, right.count))
        let x = Array(a.prefix(256)), y = Array(b.prefix(256))
        var row = Array(0...y.count)
        for (i, c) in x.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: y.count)
            for (j, d) in y.enumerated() { next[j + 1] = min(min(next[j] + 1, row[j + 1] + 1), row[j] + (c == d ? 0 : 1)) }
            row = next
        }
        return max(overlap, 1 - Double(row[y.count]) / Double(max(x.count, y.count)))
    }
    static func match(_ query: AlbumArtworkQuery, album: String, artist: String, year: Int = 0, groupCover: Bool = false) -> AlbumArtworkMatch? {
        let titleScore = similarity(base(query.album), base(album))
        let knownArtist = !["", "unknown", "unknown artist", "various", "various artists"].contains(normalize(query.artist))
        func artistBase(_ value: String) -> String {
            normalize(Regex16("(?i)\\s+(?:feat\\.?|ft\\.?|featuring)\\s+.*$").replacing(in: value, with: ""))
        }
        let artistScore = knownArtist ? similarity(artistBase(query.artist), artistBase(artist)) : 0.5
        guard titleScore >= 0.6, !knownArtist || artistScore >= 0.55 else { return nil }
        var review: [String] = []
        if titleScore < 0.95 { review.append("Check album title") }
        if !knownArtist || artistScore < 0.92 { review.append("Check artist") }
        func kind(_ title: String) -> String? {
            let title = normalize(title)
            if title.hasSuffix(" single") { return "single" }
            if title.hasSuffix(" ep") { return "ep" }
            return nil
        }
        let differentKind = kind(query.album) != kind(album) && (kind(query.album) != nil || kind(album) != nil)
        if differentKind { review.append("Check album / single / EP") }
        let differentEdition = edition(query.album) != edition(album)
        if differentEdition { review.append("Different edition") }
        let differentYear = query.year > 0 && year > 0 && abs(query.year - year) > 1
        if differentYear { review.append("Different release year") }
        if groupCover { review.append("Confirm release edition") }
        if query.year > 0 && year == 0 { review.append("Release year unavailable") }
        let score = 0.55 * titleScore + 0.4 * artistScore + (query.year == 0 || year == query.year ? 0.03 : 0) + 0.02
            - (differentEdition ? 0.18 : 0) - (differentYear ? 0.1 : 0) - (differentKind ? 0.2 : 0)
        return AlbumArtworkMatch(album: album, artist: artist, year: year, review: review, score: min(1, max(0, score)))
    }
}
