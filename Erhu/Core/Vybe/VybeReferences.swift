import Foundation

struct VybeReference: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
    let matches: [VybeNameMatch]
    var filteredOut = false
}

struct VybeReferenceAnswer: Equatable, Sendable {
    let query: String
    let references: [VybeReference]
    let wantsSimilar: Bool
    let similar: [VybeHit]
    let waitingForIndex: Bool
}

/// Finds a list of catalog references without splitting a known title/band at its own "and"
/// or comma. All possible adjacent spans are checked, with bounded, cached dynamic programming.
enum VybeReferenceParser {
    private static let separator = Regex16(#"\s+(?:and|plus|&)\s+|[,;]"#, ignoreCase: true)
    private static let maximumReferences = 8
    private struct Plan {
        var references: [(String, [VybeNameMatch])]
        var matchedWords: Int
        var missingWords: Int
        var missingCount: Int
        var ambiguousCount: Int

        func isBetter(than other: Plan) -> Bool {
            if matchedWords != other.matchedWords { return matchedWords > other.matchedWords }
            if missingWords != other.missingWords { return missingWords < other.missingWords }
            if missingCount != other.missingCount { return missingCount < other.missingCount }
            if references.count != other.references.count { return references.count < other.references.count }
            return ambiguousCount < other.ambiguousCount
        }
    }

    static func parse(_ text: String, index: VybeNameIndex, preferredKind: EntityKind?, allowMissing: Bool) -> [VybeReference]? {
        guard text.utf16Length <= 2048 else { return nil }
        let units = Array(text.utf16)
        var quoted = Set<Int>(), open: Int?
        for i in units.indices {
            if units[i] == 0x22 && (i == 0 || units[i - 1] != 0x5C) {
                if let start = open { quoted.formUnion(start...i); open = nil } else { open = i }
            } else if units[i] == 0x201C { open = i }
            else if units[i] == 0x201D, let start = open { quoted.formUnion(start...i); open = nil }
        }
        if let start = open { quoted.formUnion(start..<units.count) }
        let separators = separator.matches(in: text).filter { !quoted.contains($0.range.location) }
        guard !separators.isEmpty, separators.count <= 12 else { return nil }
        let ns = text as NSString
        let starts = [0] + separators.map { NSMaxRange($0.range) }
        let ends = separators.map { $0.range.location } + [ns.length]
        let count = starts.count
        var lookups: [String: (String, [VybeNameMatch], Int)] = [:]
        var memo: [Int: Plan] = [:]
        var impossible = Set<Int>()
        func span(_ first: Int, _ last: Int) -> (String, [VybeNameMatch], Int) {
            let key = "\(first):\(last)"
            if let cached = lookups[key] { return cached }
            let raw = ns.substring(with: NSRange(location: starts[first], length: max(ends[last] - starts[first], 0)))
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            let result = (name, index.find(name, allowPartial: true, preferredKind: preferredKind), VybeNameIndex.words(name).count)
            lookups[key] = result
            return result
        }
        func solve(_ start: Int, _ slots: Int) -> Plan? {
            if start == count { return Plan(references: [], matchedWords: 0, missingWords: 0, missingCount: 0, ambiguousCount: 0) }
            guard slots > 0 else { return nil }
            let key = start * (maximumReferences + 1) + slots
            if let cached = memo[key] { return cached }
            if impossible.contains(key) { return nil }
            var best: Plan?
            for last in start..<count {
                let (name, matches, words) = span(start, last)
                guard words > 0, let tail = solve(last + 1, slots - 1) else { continue }
                let missing = matches.isEmpty
                let candidate = Plan(references: [(name, matches)] + tail.references,
                                     matchedWords: tail.matchedWords + (missing ? 0 : words),
                                     missingWords: tail.missingWords + (missing ? words : 0),
                                     missingCount: tail.missingCount + (missing ? 1 : 0),
                                     ambiguousCount: tail.ambiguousCount + (matches.count > 1 ? 1 : 0))
                if best == nil || candidate.isBetter(than: best!) { best = candidate }
            }
            if let best { memo[key] = best } else { impossible.insert(key) }
            return best
        }
        guard let plan = solve(0, maximumReferences), plan.references.count >= 2,
              plan.references.contains(where: { !$0.1.isEmpty }),
              allowMissing || plan.missingCount == 0 else { return nil }
        return plan.references.enumerated().map { i, item in
            VybeReference(id: "\(i)|\(VybeNameIndex.normalize(item.0))", text: item.0, matches: item.1)
        }
    }
}
