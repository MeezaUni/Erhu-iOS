import Foundation

/// Unicode-safe names with bounded typo correction. Empty normalized names never match.
enum SearchNormalizer {
    private static let nonWord = Regex16(#"[^\p{L}\p{M}\p{N}]+"#)
    static func normalizeWords(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "$", with: "s").replacingOccurrences(of: "@", with: "a")
            .replacingOccurrences(of: "&", with: " and ")
        return nonWord.replacing(in: folded, with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func normalize(_ text: String) -> String { normalizeWords(text).replacingOccurrences(of: " ", with: "") }
    static func matches(_ target: String, _ query: String) -> Bool { score(target, query) > 0 }

    /// Exact names outrank prefixes, substrings, word matches and spelling corrections.
    static func score(_ target: String, _ query: String) -> Int {
        let target = normalizeWords(target), query = normalizeWords(query)
        guard !target.isEmpty, !query.isEmpty else { return 0 }
        let packedTarget = target.replacingOccurrences(of: " ", with: "")
        let packedQuery = query.replacingOccurrences(of: " ", with: "")
        if target == query || packedTarget == packedQuery { return 100 }
        if target.hasPrefix(query) { return 90 }
        if target.contains(query) || packedTarget.contains(packedQuery) { return 80 }
        let needles = query.split(separator: " ").map(String.init)
        let words = target.split(separator: " ").map(String.init)
        guard needles.count <= 16 else { return 0 }
        var unused = Set(words.indices)
        var fuzzy = false
        for needle in needles {
            if let index = unused.sorted().first(where: { words[$0] == needle || words[$0].hasPrefix(needle) }) {
                unused.remove(index); continue
            }
            let limit = allowedEdits(needle)
            guard limit > 0, let index = unused.sorted().first(where: { editDistance(needle, words[$0], limit: limit) <= limit }) else { return 0 }
            unused.remove(index); fuzzy = true
        }
        return fuzzy ? 60 : 75
    }

    static func allowedEdits(_ word: String) -> Int {
        if word.contains(where: \.isNumber) { return 0 }
        return word.count >= 8 ? 2 : word.count >= 4 ? 1 : 0
    }

    /// Damerau-Levenshtein: a swapped adjacent pair counts as one typing error.
    static func editDistance(_ first: String, _ second: String, limit: Int) -> Int {
        let a = Array(first), b = Array(second)
        guard abs(a.count - b.count) <= limit, max(a.count, b.count) <= 80 else { return limit + 1 }
        var before = Array(0...b.count), previous = before
        for i in a.indices {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (a[i] == b[j] ? 0 : 1))
                if i > 0 && j > 0 && a[i] == b[j - 1] && a[i - 1] == b[j] {
                    current[j + 1] = min(current[j + 1], before[j - 1] + 1)
                }
            }
            before = previous; previous = current
        }
        return previous.last ?? limit + 1
    }
}
