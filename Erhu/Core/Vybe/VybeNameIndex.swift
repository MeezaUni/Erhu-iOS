import Foundation

/// A library entity resolved from its stored words. This never rewrites tags or artist identity.
struct VybeNameMatch: Equatable, Sendable, Identifiable {
    let kind: EntityKind
    let name: String
    let detail: String
    let songIds: [Int64]
    var id: String { "\(kind.rawValue)|\(name)|\(detail)|\(songIds.first ?? 0)" }
    var symbol: String {
        switch kind { case .artist: "person"; case .album: "square.stack"; case .title: "music.note" }
    }
}

/// Search aliases are independent of database identity: "Kanye" can find a "Ye" credit
/// without merging artist rows or changing the listener's files.
struct VybeArtistNames {
    private let groups: [Set<String>]
    init(aliases: [String: String] = [:]) {
        var groups = [Set(["Ye", "Kanye", "Kanye West"].map(VybeNameIndex.normalize))]
        let approved = ManualArtistAliases.aliasKeys.merging(aliases) { _, new in new }
        for (alias, canonical) in approved.sorted(by: { $0.key < $1.key }) {
            let pair = Set([alias, canonical].map(VybeNameIndex.normalize))
            let overlaps = groups.indices.filter { !groups[$0].isDisjoint(with: pair) }
            let combined = overlaps.reduce(pair) { $0.union(groups[$1]) }
            for index in overlaps.reversed() { groups.remove(at: index) }
            groups.append(combined)
        }
        self.groups = groups
    }

    func forms(_ name: String) -> Set<String> {
        let normalized = VybeNameIndex.normalize(name)
        return groups.first(where: { $0.contains(normalized) }) ?? [normalized]
    }

    func key(_ name: String) -> String { forms(name).sorted().first ?? "" }

    func mentionedName(in query: String, credit: String) -> String? {
        let terms = VybeNameIndex.words(query)
        return MusicQueryIntent.artists(credit).first { name in
            guard !["unknown", "unknown artist", "various artists"].contains(VybeNameIndex.normalize(name)) else { return false }
            return forms(name).contains { containsSequence(terms, VybeNameIndex.words($0)) }
        }
    }
}

/// Cached, small word postings for artist credits, album names and titles. Semantic vectors
/// deliberately exclude titles; name retrieval therefore has its own index and matching rules.
struct VybeNameIndex {
    private struct Entry {
        let match: VybeNameMatch
        let forms: Set<String>
    }
    private struct Builder {
        var name: String
        var detail: String
        var ids: Set<Int64> = []
        var forms: Set<String> = []
    }
    let artistNames: VybeArtistNames
    private let entries: [Entry]
    private let exact: [String: Set<Int>]
    private let postings: [String: Set<Int>]
    private let artists: [ArtistEntry]
    private struct ArtistEntry {
        let match: VybeNameMatch
        let ids: Set<Int64>
        let words: [[String]]
    }

    init(songs: [SongText], aliases: [String: String] = [:]) {
        let artistNames = VybeArtistNames(aliases: aliases)
        self.artistNames = artistNames
        var groups: [String: (EntityKind, Builder)] = [:]
        func add(_ kind: EntityKind, _ name: String, detail: String, key: String, forms: Set<String>, id: Int64) {
            guard !Self.normalize(name).isEmpty, !["unknown", "unknown artist", "unknown album"].contains(Self.normalize(name)) else { return }
            let groupKey = kind.rawValue + "|" + key
            var group = groups[groupKey]?.1 ?? Builder(name: name, detail: detail)
            group.ids.insert(id)
            group.forms.formUnion(forms)
            groups[groupKey] = (kind, group)
        }
        for song in songs.sorted(by: { $0.songId < $1.songId }) {
            for artist in Set(MusicQueryIntent.artists(song.artist)).sorted() {
                let creditKey = CreditText.canonicalKey(artist)
                let canonical = ManualArtistAliases.aliasKeys[creditKey] ?? creditKey
                let display = ManualArtistAliases.artistNames[canonical] ?? artist
                add(.artist, display, detail: "Artist", key: artistNames.key(artist), forms: artistNames.forms(artist), id: song.songId)
            }
            let title = Self.normalize(song.title), album = Self.normalize(song.album)
            add(.album, song.album, detail: "Album", key: album, forms: [album], id: song.songId)
            add(.title, song.title, detail: song.artist, key: title + "|" + artistNames.key(song.artist), forms: [title], id: song.songId)
        }
        let entries = groups.sorted(by: { $0.key < $1.key }).map { _, value in
            Entry(match: VybeNameMatch(kind: value.0, name: value.1.name, detail: value.1.detail, songIds: value.1.ids.sorted()), forms: value.1.forms)
        }
        self.entries = entries
        self.artists = entries.filter { $0.match.kind == .artist }.map {
            ArtistEntry(match: $0.match, ids: Set($0.match.songIds), words: $0.forms.map(Self.words))
        }
        var exact: [String: Set<Int>] = [:], postings: [String: Set<Int>] = [:]
        for (index, entry) in entries.enumerated() {
            for form in entry.forms {
                exact[form, default: []].insert(index)
                for word in Self.words(form) { postings[word, default: []].insert(index) }
            }
        }
        self.exact = exact
        self.postings = postings
    }

    /// Exact names beat partial names, which beat a limited spelling correction. Short aliases
    /// resolve only as complete words; "Ye" must never be extracted from "Yelawolf".
    func find(_ text: String, allowPartial: Bool, preferredKind: EntityKind? = nil) -> [VybeNameMatch] {
        lookup(text, allowPartial: allowPartial, preferredKind: preferredKind, qualified: true)
    }

    private func lookup(_ text: String, allowPartial: Bool, preferredKind: EntityKind?, qualified: Bool, allowed: Set<Int64>? = nil) -> [VybeNameMatch] {
        let normalized = Self.normalize(text)
        func inScope(_ index: Int) -> Bool { allowed.map { !Set(entries[index].match.songIds).isDisjoint(with: $0) } ?? true }
        if let ids = exact[normalized] {
            let matching = matches(Set(ids.filter(inScope)), preferKind: true, preferredKind: preferredKind, allowed: allowed)
            if !matching.isEmpty { return matching }
        }
        guard allowPartial else { return [] }
        let compound = qualified ? qualifiedMatches(text, preferredKind: preferredKind) : []
        let words = Self.words(text)
        guard !words.isEmpty, words.joined().count >= 3 else { return [] }
        var candidates: Set<Int>?
        for (position, word) in words.enumerated() {
            var ids = postings[word] ?? []
            if position == words.count - 1 && word.count >= 3 {
                for (token, matches) in postings where token.hasPrefix(word) { ids.formUnion(matches) }
            }
            candidates = candidates.map { $0.intersection(ids) } ?? ids
        }
        let partial = (candidates ?? []).filter { inScope($0) && matchesForm(entries[$0], words: words, fuzzy: false) }
        if !partial.isEmpty || !compound.isEmpty {
            var combined = Dictionary(matches(Set(partial), preferKind: false, preferredKind: preferredKind, allowed: allowed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for match in compound { combined[match.id] = match }
            let ordered = combined.values.sorted {
                if $0.kind != $1.kind { return Self.priority($0.kind) < Self.priority($1.kind) }
                return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
            }
            if let preferredKind, ordered.contains(where: { $0.kind == preferredKind }) { return ordered.filter { $0.kind == preferredKind } }
            return ordered
        }
        // One edit (including an adjacent transposition) for 4+ letters, two for 8+.
        // Every query word must match the same name form, avoiding unrelated word fragments.
        guard words.allSatisfy({ $0.count >= 3 }), words.contains(where: { $0.count >= 4 }) else { return [] }
        var fuzzy: Set<Int>?
        for word in words {
            var ids = postings[word] ?? []
            let allowed = Self.allowedEdits(word)
            for (token, matches) in postings where allowed > 0 && Self.editDistance(word, token, limit: allowed) <= allowed { ids.formUnion(matches) }
            fuzzy = fuzzy.map { $0.intersection(ids) } ?? ids
        }
        return matches(Set((fuzzy ?? []).filter { inScope($0) && matchesForm(entries[$0], words: words, fuzzy: true) }), preferKind: false, preferredKind: preferredKind, allowed: allowed)
    }

    /// Artist and title are separate facts. An artist span must belong to the matched title's
    /// own song IDs; words from different songs must never be combined into a match.
    private func qualifiedMatches(_ text: String, preferredKind: EntityKind?) -> [VybeNameMatch] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let query = Self.queryWord.matches(in: folded).map { $0.group(0, in: folded) }
        guard (2...40).contains(query.count) else { return [] }
        var found: [String: VybeNameMatch] = [:]
        for artist in artists {
            for words in artist.words where !words.isEmpty && words.count <= query.count {
                for start in 0...(query.count - words.count) {
                    let end = start + words.count
                    guard words.indices.allSatisfy({ offset in
                        let value = query[start + offset], word = words[offset]
                        if Self.normalize(value) == word { return true }
                        guard offset == words.count - 1 else { return false }
                        if value.hasSuffix("'s") || value.hasSuffix("’s") {
                            return Self.normalize(String(value.dropLast(2))) == word
                        }
                        return word.count >= 3 && value == word + "s"
                    }) else { continue }
                    var left = Array(query[..<start]), right = Array(query[end...])
                    if let last = left.last, ["by", "from", "of"].contains(last) { left.removeLast() }
                    while right.count > 1, let first = right.first, ["song", "songs", "track", "tracks", "called", "titled"].contains(first) { right.removeFirst() }
                    while left.count > 1, let last = left.last, ["song", "track", "called", "titled"].contains(last) { left.removeLast() }
                    let remaining = (left + right).joined(separator: " ")
                    if remaining.isEmpty {
                        found[artist.match.id] = artist.match
                        continue
                    }
                    let kind: EntityKind = preferredKind == .album ? .album : .title
                    for title in lookup(remaining, allowPartial: true, preferredKind: kind, qualified: false, allowed: artist.ids) where title.kind != .artist {
                        if let preferredKind, preferredKind != .artist && title.kind != preferredKind { continue }
                        let ids = title.songIds.filter(artist.ids.contains)
                        guard !ids.isEmpty else { continue }
                        let match = VybeNameMatch(kind: title.kind, name: title.name, detail: title.detail, songIds: ids)
                        found[match.id] = match
                    }
                }
            }
        }
        return found.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    private func matchesForm(_ entry: Entry, words: [String], fuzzy: Bool) -> Bool {
        entry.forms.contains { form in
            let tokens = Self.words(form)
            var unused = Set(tokens.indices)
            for (position, word) in words.enumerated() {
                let allowed = fuzzy ? Self.allowedEdits(word) : 0
                let exact = unused.sorted().first { tokens[$0] == word }
                let other = unused.sorted().first {
                    (!fuzzy && position == words.count - 1 && word.count >= 3 && tokens[$0].hasPrefix(word))
                        || (fuzzy && Self.editDistance(word, tokens[$0], limit: allowed) <= allowed)
                }
                guard let chosen = exact ?? other else { return false }
                unused.remove(chosen)
            }
            return true
        }
    }

    private func matches(_ ids: Set<Int>, preferKind: Bool, preferredKind: EntityKind?, allowed: Set<Int64>? = nil) -> [VybeNameMatch] {
        let ordered = ids.compactMap { index -> VybeNameMatch? in
            let match = entries[index].match
            guard let allowed else { return match }
            let scoped = match.songIds.filter(allowed.contains)
            return scoped.isEmpty ? nil : VybeNameMatch(kind: match.kind, name: match.name, detail: match.detail, songIds: scoped)
        }.sorted {
            if $0.kind != $1.kind { return Self.priority($0.kind) < Self.priority($1.kind) }
            return $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id
        }
        if let preferredKind, ordered.contains(where: { $0.kind == preferredKind }) { return ordered.filter { $0.kind == preferredKind } }
        if preferKind, let kind = ordered.first?.kind { return ordered.filter { $0.kind == kind } }
        return ordered
    }

    private static func priority(_ kind: EntityKind) -> Int {
        switch kind { case .artist: 0; case .album: 1; case .title: 2 }
    }

    private static func allowedEdits(_ word: String) -> Int {
        if word.contains(where: \.isNumber) { return 0 }
        return word.count >= 8 ? 2 : (word.count >= 4 ? 1 : 0)
    }

    private static let nonWord = Regex16(#"[^\p{L}\p{N}]+"#)
    private static let queryWord = Regex16(#"\p{L}+(?:['’]s\b)?|\p{N}+"#)
    private static let letterNumberBoundary = Regex16(#"(?<=\p{L})(?=\p{N})|(?<=\p{N})(?=\p{L})"#)
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return nonWord.replacing(in: letterNumberBoundary.replacing(in: folded, with: " "), with: " ").trimmed
    }
    static func words(_ text: String) -> [String] { normalize(text).split(separator: " ").map(String.init) }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit, max(a.count, b.count) <= 80 else { return limit + 1 }
        var previousPrevious = Array(0...b.count), previous = previousPrevious
        for i in a.indices {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                current[j + 1] = min(current[j] + 1, min(previous[j + 1] + 1, previous[j] + (a[i] == b[j] ? 0 : 1)))
                if i > 0 && j > 0 && a[i] == b[j - 1] && a[i - 1] == b[j] { current[j + 1] = min(current[j + 1], previousPrevious[j - 1] + 1) }
            }
            previousPrevious = previous
            previous = current
        }
        return previous.last ?? limit + 1
    }
}
