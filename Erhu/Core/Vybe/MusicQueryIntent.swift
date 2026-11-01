import Foundation

/// Only explicit, verifiable metadata constraints are hard filters. A mood remains semantic;
/// missing BPM/year is never invented, and an excluded genre must not become a positive boost.
struct MusicQueryIntent {
    let text: String
    let excluded: Set<Int64>
    let bpm: ClosedRange<Int>?
    let years: ClosedRange<Int>?

    init(_ query: String, songs: [SongText]) {
        var removed: [NSRange] = []
        var excluded = Set<Int64>()
        let hasExclusion = Regex16(#"\b(?:no|not|without|excluding|exclude|except)\b"#, ignoreCase: true).containsMatch(in: query)
        let genres = hasExclusion ? Set(songs.flatMap(\.genres)) : []
        let artists = hasExclusion ? Set(songs.map(\.artist)) : []
        let candidates = Set(genres.flatMap(MusicGenres.aliases) + artists.flatMap(Self.artists))
        for candidate in candidates where candidate.utf16Length >= 3 && query.range(of: candidate, options: .caseInsensitive) != nil {
            let escaped = NSRegularExpression.escapedPattern(for: candidate)
            let regex = Regex16("\\b(?:no|not|without|excluding|exclude|except)\\s+(?:any\\s+)?" + escaped + "(?![\\p{L}\\p{N}])", ignoreCase: true)
            let matches = regex.matches(in: query)
            guard !matches.isEmpty else { continue }
            removed += matches.map(\.range)
            for song in songs where song.genres.contains(where: { MusicGenres.matches(candidate, genre: $0) })
                || Self.artists(song.artist).contains(where: { MusicGenres.normalize($0) == MusicGenres.normalize(candidate) }) {
                excluded.insert(song.songId)
            }
        }
        self.excluded = excluded
        var bpm: ClosedRange<Int>?
        for (pattern, bounds) in Self.tempoPatterns {
            guard let match = Regex16(pattern, ignoreCase: true).firstMatch(in: query),
                  let range = bounds(match, query) else { continue }
            bpm = range
            removed.append(match.range)
            break
        }
        self.bpm = bpm
        var years: ClosedRange<Int>?
        let decade = Regex16(#"\b(?:from\s+|in\s+)?the\s+((?:19|20)?\d0)['’]?s\b|\b((?:19|20)\d0)['’]?s\b"#, ignoreCase: true)
        if let match = decade.firstMatch(in: query),
           let value = Int(match.group(1, in: query).ifBlank(match.group(2, in: query))) {
            let year = value < 100 ? (value >= 50 ? 1900 : 2000) + value : value
            years = year...(year + 9)
            removed.append(match.range)
        } else if let match = Regex16(#"\b(?:from|in|released in|year)\s+((?:19|20)\d{2})\b"#, ignoreCase: true).firstMatch(in: query),
                  let year = Int(match.group(1, in: query)) {
            years = year...year
            removed.append(match.range)
        }
        self.years = years
        // Replace matched clauses together so overlapping aliases cannot damage UTF-16 ranges.
        let ns = query as NSString
        var clean = ""
        var end = 0
        for range in removed.sorted(by: { $0.location < $1.location }) {
            if range.location > end { clean += ns.substring(with: NSRange(location: end, length: range.location - end)) }
            clean += " "
            end = max(end, range.location + range.length)
        }
        clean += ns.substring(from: end)
        text = Regex16(#"[\s,]+"#).replacing(in: clean, with: " ").trimmed
    }

    func allows(_ song: SongText) -> Bool {
        if excluded.contains(song.songId) { return false }
        if let bpm, !bpm.contains(song.bpm ?? -1) { return false }
        if let years, !years.contains(song.year) { return false }
        return true
    }

    private static let creditSplit = Regex16(#"\s*(?:/|,|&|;|\bfeat\.?|\bft\.?|\bx\b)\s*"#, ignoreCase: true)
    static func artists(_ credit: String) -> [String] {
        [credit] + creditSplit.split(credit).map(\.trimmed).filter { !$0.isEmpty }
    }

    private static let tempoPatterns: [(String, (NSTextCheckingResult, String) -> ClosedRange<Int>?)] = [
        (#"\b(?:between\s+)?(\d{2,3})\s*(?:-|–|to|and)\s*(\d{2,3})\s*(?:bpm|beats per minute)\b"#,
         { m, s in MusicQueryIntent.range(m.group(1, in: s), m.group(2, in: s)) }),
        (#"\b(?:under|below|less than)\s+(\d{2,3})\s*bpm\b"#,
         { m, s in Int(m.group(1, in: s)).flatMap { MusicQueryIntent.range(20, $0 - 1) } }),
        (#"\b(?:over|above|more than)\s+(\d{2,3})\s*bpm\b"#,
         { m, s in Int(m.group(1, in: s)).flatMap { MusicQueryIntent.range($0 + 1, 400) } }),
        (#"\b(?:around|about)\s+(\d{2,3})\s*bpm\b"#,
         { m, s in Int(m.group(1, in: s)).flatMap { MusicQueryIntent.range($0 - 5, $0 + 5) } }),
        (#"\b(\d{2,3})\s*bpm\b"#,
         { m, s in MusicQueryIntent.range(m.group(1, in: s), m.group(1, in: s)) }),
    ]

    private static func range(_ lower: String, _ upper: String) -> ClosedRange<Int>? {
        guard let a = Int(lower), let b = Int(upper) else { return nil }
        return range(a, b)
    }
    private static func range(_ lower: Int, _ upper: Int) -> ClosedRange<Int>? {
        let a = max(20, lower), b = min(400, upper)
        return a <= b ? a...b : nil
    }
}

enum MusicGenres {
    private static let separators = Regex16(#"[^\p{L}\p{N}]+"#)
    private static let groups = [
        ["hip-hop", "hip hop", "hiphop", "rap"],
        ["r&b", "rnb", "r n b", "rhythm and blues"],
        ["edm", "electronic dance music"],
        ["lo-fi", "lofi", "lo fi"],
        ["drum and bass", "drum & bass", "dnb", "d&b"],
    ]

    static func normalize(_ text: String) -> String {
        separators.replacing(in: text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")), with: " ").trimmed
    }

    static func aliases(_ genre: String) -> [String] {
        let normalized = normalize(genre)
        var result = [genre]
        for group in groups where group.contains(where: { containsSequence(normalized.split(separator: " ").map(String.init), normalize($0).split(separator: " ").map(String.init)) }) {
            result += group
        }
        // These subgenres are members of rap, even when a tag omits the parent genre.
        if ["trap", "drill", "boom bap"].contains(normalized) { result += groups[0] }
        return result
    }

    static func matches(_ text: String, genre: String) -> Bool {
        let words = normalize(text).split(separator: " ").map(String.init)
        return aliases(genre).contains { containsSequence(words, normalize($0).split(separator: " ").map(String.init)) }
    }
}
