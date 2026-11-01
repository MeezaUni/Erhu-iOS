import Foundation

/// What a name in a query was found as in the library.
enum EntityKind: String, Sendable { case artist, album, title }

/// How VYBE answers a query.
enum VybeRoute: Equatable, Sendable {
    /// The query names a library artist, album or title: [songIds] are the songs it names, found
    /// exactly from metadata. [wantsSimilar] is true for "like …" queries.
    case named(kind: EntityKind, name: String, songIds: [Int64], wantsSimilar: Bool)
    /// A "like …" / "from …" query whose name matches nothing in the library.
    case unknownName(name: String, query: String)
    case ambiguous(name: String, matches: [VybeNameMatch], wantsSimilar: Bool)
    case references([VybeReference], wantsSimilar: Bool)
    /// Not about a name: a mood / activity description for semantic search.
    case describe(query: String)
}

/// Name retrieval precedes embeddings, using the library's own word index and search aliases.
/// Partial names and small spelling errors resolve only when the entity is unambiguous.
enum VybeQueryRouter {
    private static let patterns: [(Regex16, Bool, EntityKind?)] = [
        (Regex16(#"^(?:play\s+)?(?:some\s+)?albums?\s+(?:like|similar to)\s+(.+)$"#), true, .album),
        (Regex16(#"^(?:play\s+)?(?:some\s+)?artists?\s+(?:like|similar to)\s+(.+)$"#), true, .artist),
        (Regex16(#"^(?:play\s+)?(?:some\s+)?(?:songs?|music|tracks?|stuff)\s+(?:like|similar to)\s+(.+)$"#), true, .title),
        (Regex16(#"^(?:more\s+)?(?:like|similar to)\s+(.+)$"#), true, nil),
        (Regex16(#"^(?:play\s+)?(?:more\s+)?(?:songs?|music|tracks?)?\s*(?:from|by|in)\s+(.+)$"#), false, .artist),
    ]

    static func route(_ query: String, songs: [SongText]) -> VybeRoute {
        route(query, index: VybeNameIndex(songs: songs))
    }

    static func route(_ query: String, index: VybeNameIndex) -> VybeRoute {
        let original = query.trimmed
        let text = original.lowercased()
        var found: (String, Bool, EntityKind?)?
        for (regex, similar, kind) in patterns {
            guard let match = regex.firstMatch(in: text) else { continue }
            let range = match.range(at: 1)
            let name = original.utf16Length == text.utf16Length
                ? (original as NSString).substring(with: range) : match.group(1, in: text)
            found = (name.trimmed, similar, kind)
            break
        }
        let name = found?.0 ?? original
        let wantsSimilar = found?.1 ?? false
        if found == nil && VybeNameIndex.words(original).allSatisfy({ ["music", "song", "songs", "tracks", "stuff", "play", "some"].contains($0) }) {
            return .describe(query: original)
        }
        let moodWords: Set<String> = ["sad", "happy", "chill", "dark", "calm", "fast", "slow", "relax", "relaxing", "workout", "gym", "sleep", "energetic", "mellow", "music", "songs", "vibes", "rap", "hiphop", "rock", "jazz", "metal", "pop", "soul", "ambient"]
        if found == nil && index.find(name, allowPartial: false).isEmpty && !Set(VybeNameIndex.words(name)).isDisjoint(with: moodWords) {
            return .describe(query: original)
        }
        let matches = index.find(name, allowPartial: true, preferredKind: found?.2)
        if matches.count == 1, let match = matches.first {
            return .named(kind: match.kind, name: match.name, songIds: match.songIds, wantsSimilar: wantsSimilar)
        }
        if !matches.isEmpty { return .ambiguous(name: name, matches: matches, wantsSimilar: wantsSimilar) }
        if let references = VybeReferenceParser.parse(name, index: index, preferredKind: found?.2, allowMissing: found != nil) {
            return .references(references, wantsSimilar: wantsSimilar)
        }
        return found == nil ? .describe(query: original) : .unknownName(name: name, query: original)
    }
}

/// The needle's words appear in order, back to back, somewhere in the haystack.
func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return (0...(haystack.count - needle.count)).contains { start in Array(haystack[start..<(start + needle.count)]) == needle }
}
