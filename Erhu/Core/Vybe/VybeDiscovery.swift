import Foundation

/// What a text is embedded as: a user's search query, or a song description being searched.
enum EmbeddingRole: Equatable, Sendable { case query, document }

/// Turns text into a vector, entirely on the device. Nothing in VYBE depends on which model
/// produces the vectors. Implementations run synchronously: call from a background context.
protocol TextEmbedder {
    /// Identifies the model and its settings: an index written by another model is discarded.
    var modelId: String { get }
    /// Length of every vector this embedder returns.
    var dimension: Int { get }
    /// Best similarity below this: nothing in the library is described like the query.
    var weakBest: Float { get }

    func embed(_ text: String, role: EmbeddingRole) throws -> [Float]
}

/// Where song vectors come from when ranking (the on-disk index in the app, a map in tests).
protocol SongVectors {
    /// The [limit] best songs by [score] (nil leaves a song out), best first.
    func rank(limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch]
    func vectorOf(_ songId: Int64) -> [Float]?
}

struct VybeMatch: Equatable, Sendable {
    let songId: Int64
    let score: Float
}

/// A discovered song, its score, and why it is there (shown to the user).
struct VybeHit: Equatable, Sendable {
    let songId: Int64
    let score: Float
    let reasons: [String]
}

/// VYBE's answer to one query.
enum VybeAnswer: Equatable, Sendable {
    /// The query named library songs exactly: those songs, and for "like …" queries the songs
    /// nearest to them by genre and tempo.
    case named(kind: EntityKind, name: String, songIds: [Int64], similar: [VybeHit])
    /// A described mood or style matched against each song's description. [weak]: no song is
    /// close, or the scores barely separate the library. [unknownName]: the query named
    /// something the library doesn't have.
    case described(query: String, hits: [VybeHit], weak: Bool, unknownName: String?)
    /// Songs nearest to [seedSongId] by their description.
    case similarTo(seedSongId: Int64, hits: [VybeHit])
    case ambiguous(query: String, matches: [VybeNameMatch], wantsSimilar: Bool)
    case references(VybeReferenceAnswer)
}

/// VYBE's hybrid search over the listener's own songs:
/// 1. [VybeQueryRouter]: a query naming a library artist, album or title is answered exactly.
/// 2. Otherwise the query is embedded and compared with each song's description vector.
/// 3. Metadata the query names outright counts: songs by a named library artist come first, a
///    named library genre is boosted, and tempo words only nudge songs whose BPM tag fits.
/// Songs without genre or BPM stay in: they are ranked by what they have.
struct VybeDiscovery {
    static let similarReason = "Similar genre and tempo"
    static let artistBoost: Float = 0.15
    static let genreBoost: Float = 0.08
    static let tempoBoost: Float = 0.03
    /// Best-vs-median similarity below this: the query doesn't separate the library's songs.
    static let weakSpread: Float = 0.03

    private static let fastWords: Set<String> =
        ["gym", "workout", "energy", "energetic", "high-energy", "hype", "fast", "running", "run", "party", "upbeat", "pump"]
    private static let slowWords: Set<String> =
        ["mellow", "slow", "chill", "calm", "relax", "relaxing", "sleep", "late-night", "soft", "laid-back", "quiet"]
    private static let fastBpm = 120
    private static let slowBpm = 95
    private static let word = Regex16(#"[\p{L}\p{N}&$]+(?:-[\p{L}\p{N}]+)*"#)
    private static let notArtists: Set<String> = ["unknown", "<unknown>", "unknown artist", "various artists"]

    let embedder: TextEmbedder
    let vectors: SongVectors
    private let names: VybeNameIndex?

    init(embedder: TextEmbedder, vectors: SongVectors, names: VybeNameIndex? = nil) {
        self.embedder = embedder
        self.vectors = vectors
        self.names = names
    }

    func search(_ query: String, songs: [SongText], limit: Int, selections: [String: VybeNameMatch] = [:]) throws -> VybeAnswer {
        let text = query.trimmed
        let names = self.names ?? VybeNameIndex(songs: songs)
        let intent = MusicQueryIntent(text, songs: songs, artistNames: names.artistNames)
        let eligible = songs.filter(intent.allows)
        let allowed = Set(eligible.map(\.songId))
        switch VybeQueryRouter.route(intent.text, index: names) {
        case .named(let kind, let name, let songIds, let wantsSimilar):
            let matched = songIds.filter(allowed.contains)
            let similar = wantsSimilar && !matched.isEmpty ? similarTo(Set(matched), limit: limit, allowed: allowed) : []
            return .named(kind: kind, name: name, songIds: matched, similar: similar)
        case .unknownName(let name, _):
            return try describe(text, embeddingText: intent.text, songs: eligible, limit: limit, unknownName: name, names: names)
        case .describe:
            return try describe(text, embeddingText: intent.text, songs: eligible, limit: limit, unknownName: nil, names: names)
        case .ambiguous(_, let matches, let wantsSimilar):
            let choices = matches.compactMap { match -> VybeNameMatch? in
                let ids = match.songIds.filter(allowed.contains)
                return ids.isEmpty ? nil : VybeNameMatch(kind: match.kind, name: match.name, detail: match.detail, songIds: ids)
            }
            if choices.count == 1, let choice = choices.first { return select(choice, query: text, songs: songs, wantsSimilar: wantsSimilar, limit: limit) }
            return .ambiguous(query: text, matches: Array(choices.prefix(12)), wantsSimilar: wantsSimilar)
        case .references(let references, let wantsSimilar):
            let resolved = references.map { reference -> VybeReference in
                var choices = reference.matches.compactMap { match -> VybeNameMatch? in
                    let ids = match.songIds.filter(allowed.contains)
                    return ids.isEmpty ? nil : VybeNameMatch(kind: match.kind, name: match.name, detail: match.detail, songIds: ids)
                }
                if let selected = selections[reference.id], let choice = choices.first(where: {
                    $0.kind == selected.kind && $0.name == selected.name && $0.detail == selected.detail
                        && Set($0.songIds) == Set(selected.songIds)
                }) { choices = [choice] }
                return VybeReference(id: reference.id, text: reference.text, matches: choices,
                                     filteredOut: !reference.matches.isEmpty && choices.isEmpty)
            }
            let seeds = resolved.compactMap { $0.matches.count == 1 ? $0.matches.first?.songIds : nil }
            let needsChoice = resolved.contains { $0.matches.count > 1 }
            let ranked = wantsSimilar && !needsChoice ? similarToReferences(seeds, limit: limit, allowed: allowed) : ([], false)
            return .references(VybeReferenceAnswer(query: text, references: resolved, wantsSimilar: wantsSimilar,
                                                   similar: ranked.0, waitingForIndex: ranked.1))
        }
    }

    /// Every reference gets one vote, even when one names an artist's entire catalog. Normalize
    /// individual vectors before averaging, and reward candidates close to every reference.
    /// Never silently rank from just one seed while another is still being indexed.
    private func similarToReferences(_ groups: [[Int64]], limit: Int, allowed: Set<Int64>) -> ([VybeHit], Bool) {
        var seen = Set<Set<Int64>>()
        let groups = groups.map(Set.init).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !groups.isEmpty else { return ([], false) }
        func unit(_ vector: [Float]) -> [Float]? {
            let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard !vector.isEmpty, norm.isFinite, norm > 0 else { return nil }
            return vector.map { Float(Double($0) / norm) }
        }
        var centroids: [[Float]] = []
        for group in groups {
            let units = group.sorted().compactMap { vectors.vectorOf($0).flatMap(unit) }
            guard units.count == group.count, let first = units.first,
                  units.allSatisfy({ $0.count == first.count }) else { return ([], true) }
            var sum = [Float](repeating: 0, count: first.count)
            for vector in units { for i in sum.indices { sum[i] += vector[i] / Float(units.count) } }
            guard let centroid = unit(sum) else { return ([], true) }
            centroids.append(centroid)
        }
        let excluded = groups.reduce(into: Set<Int64>()) { $0.formUnion($1) }
        let hits = vectors.rank(limit: limit) { id, vector in
            guard allowed.contains(id), !excluded.contains(id) else { return nil }
            let scores = centroids.compactMap { cosineSimilarity($0, vector) }
            guard scores.count == centroids.count, let weakest = scores.min() else { return nil }
            return 0.75 * scores.reduce(0, +) / Float(scores.count) + 0.25 * weakest
        }.map { VybeHit(songId: $0.songId, score: $0.score,
                        reasons: [centroids.count > 1 ? "Similar to your references" : Self.similarReason]) }
        return (hits, false)
    }

    func select(_ match: VybeNameMatch, query: String, songs: [SongText], wantsSimilar: Bool, limit: Int) -> VybeAnswer {
        let names = self.names ?? VybeNameIndex(songs: songs)
        let intent = MusicQueryIntent(query, songs: songs, artistNames: names.artistNames)
        let allowed = Set(songs.filter(intent.allows).map(\.songId))
        let seeds = match.songIds.filter(allowed.contains)
        let similar = wantsSimilar && !seeds.isEmpty ? similarTo(Set(seeds), limit: limit, allowed: allowed) : []
        return .named(kind: match.kind, name: match.name, songIds: seeds, similar: similar)
    }

    /// Songs nearest to [songId]'s own description, itself excluded.
    func similarToSong(_ songId: Int64, limit: Int) -> VybeAnswer {
        .similarTo(seedSongId: songId, hits: similarTo([songId], limit: limit))
    }

    private func similarTo(_ seeds: Set<Int64>, limit: Int, allowed: Set<Int64>? = nil) -> [VybeHit] {
        let seedVectors = seeds.sorted().compactMap { vectors.vectorOf($0) }
        guard let first = seedVectors.first else { return [] }
        var centroid = [Float](repeating: 0, count: first.count)
        for i in centroid.indices {
            var sum = 0.0
            for vector in seedVectors { sum += Double(vector[i]) }
            centroid[i] = Float(sum) / Float(seedVectors.count)
        }
        return vectors.rank(limit: limit) { id, v in
            seeds.contains(id) || allowed.map({ !$0.contains(id) }) == true ? nil : cosineSimilarity(centroid, v)
        }
            .map { VybeHit(songId: $0.songId, score: $0.score, reasons: [Self.similarReason]) }
    }

    private func describe(_ query: String, embeddingText: String, songs: [SongText], limit: Int, unknownName: String?, names: VybeNameIndex) throws -> VybeAnswer {
        if query.isEmpty || songs.isEmpty || limit <= 0 {
            return .described(query: query, hits: [], weak: false, unknownName: unknownName)
        }
        let queryVector = try embedder.embed(embeddingText.ifBlank("music"), role: .query)
        let boosts = Self.metadataBoosts(embeddingText, songs: songs, names: names)
        // Scores of all songs (cheap: a dot product each) to judge whether the query separates them.
        let eligible = Set(songs.map(\.songId))
        let all = vectors.rank(limit: max(songs.count, 1)) { id, v in eligible.contains(id) ? cosineSimilarity(queryVector, v) : nil }
        let weak = Self.isWeak(all.map(\.score), weakBest: embedder.weakBest)
        var ranked = all.map { match -> (VybeMatch, Float, Bool) in
            let reasons = boosts[match.songId] ?? []
            return (match, reasons.reduce(Float(0)) { $0 + $1.1 }, reasons.contains { $0.1 == Self.artistBoost })
        }.sorted { a, b in
            // Songs by an artist the query names come first, whatever their description scores.
            if a.2 != b.2 { return a.2 }
            let sa = a.0.score + a.1
            let sb = b.0.score + b.1
            return sa != sb ? sa > sb : a.0.songId < b.0.songId
        }
        // A small repeat penalty broadens close results without promoting weak matches or
        // moving songs ahead of an artist the listener explicitly named.
        let byId = Dictionary(songs.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })
        let keys = byId.mapValues { song -> (artist: String, album: String?) in
            let artist = MusicGenres.normalize(song.artist)
            let known = !artist.isEmpty && !Self.notArtists.contains(artist)
            let key = known ? artist : "unknown:\(song.songId)"
            return (key, song.album.isBlank ? nil : key + "|" + MusicGenres.normalize(song.album))
        }
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var hits: [VybeHit] = []
        while !ranked.isEmpty && hits.count < limit {
            let hasNamedArtist = ranked.contains { $0.2 }
            func adjusted(_ item: (VybeMatch, Float, Bool)) -> Float {
                guard let key = keys[item.0.songId] else { return -.infinity }
                let repeatArtist = min(artistCounts[key.artist, default: 0], 3)
                let repeatAlbum = key.album.map { min(albumCounts[$0, default: 0], 2) } ?? 0
                return item.0.score + item.1 - Float(repeatArtist) * 0.025 - Float(repeatAlbum) * 0.015
            }
            let candidates = ranked.indices.filter { !hasNamedArtist || ranked[$0].2 }
            let best = candidates.max { a, b in
                let sa = adjusted(ranked[a]), sb = adjusted(ranked[b])
                return sa == sb ? ranked[a].0.songId > ranked[b].0.songId : sa < sb
            }!
            let (match, boost, _) = ranked.remove(at: best)
            hits.append(VybeHit(songId: match.songId, score: match.score + boost, reasons: (boosts[match.songId] ?? []).map(\.0)))
            if let key = keys[match.songId] {
                artistCounts[key.artist, default: 0] += 1
                if let album = key.album { albumCounts[album, default: 0] += 1 }
            }
        }
        return .described(query: query, hits: hits, weak: weak, unknownName: unknownName)
    }

    static func isWeak(_ scores: [Float], weakBest: Float) -> Bool {
        if scores.isEmpty { return false }
        let sorted = scores.sorted(by: >)
        if sorted[0] < weakBest { return true }
        return sorted.count >= 2 && sorted[0] - sorted[sorted.count / 2] < weakSpread
    }

    /// Per song: (reason, boost) for metadata the query names outright.
    static func metadataBoosts(_ query: String, songs: [SongText], names: VybeNameIndex? = nil) -> [Int64: [(String, Float)]] {
        let queryWords = words(query)
        let requestedGenres = Set(Set(songs.flatMap(\.genres)).filter { MusicGenres.matches(query, genre: $0) })
        let aliases = names?.artistNames ?? VybeArtistNames()
        let artists = Dictionary(uniqueKeysWithValues: Set(songs.map(\.artist)).compactMap { credit -> (String, String)? in
            guard let name = aliases.mentionedName(in: query, credit: credit) else { return nil }
            return (credit, name)
        })
        var boosts: [Int64: [(String, Float)]] = [:]
        for song in songs {
            if let artist = artists[song.artist], !notArtists.contains(artist.lowercased()) {
                boosts[song.songId, default: []].append(("Artist: \(artist)", artistBoost))
            }
            if let genre = song.genres.first(where: requestedGenres.contains) {
                boosts[song.songId, default: []].append(("Genre: \(genre)", genreBoost))
            }
            if let bpm = song.bpm, VybeText.plausibleBpm.contains(bpm) {
                if hasPositiveTempoWord(queryWords, matching: fastWords) && bpm >= fastBpm {
                    boosts[song.songId, default: []].append(("Tempo: \(bpm) BPM (tag)", tempoBoost))
                } else if hasPositiveTempoWord(queryWords, matching: slowWords) && bpm <= slowBpm {
                    boosts[song.songId, default: []].append(("Tempo: \(bpm) BPM (tag)", tempoBoost))
                }
            }
        }
        return boosts
    }

    private static func hasPositiveTempoWord(_ words: [String], matching terms: Set<String>) -> Bool {
        words.indices.contains { i in
            terms.contains(words[i]) && (i == 0 || !["not", "no", "without", "except"].contains(words[i - 1]))
        }
    }

    private static func words(_ text: String) -> [String] {
        let lower = text.lowercased()
        return word.matches(in: lower).map { (lower as NSString).substring(with: $0.range) }
    }
}

/// Cosine similarity of two vectors; nil when they cannot be compared (empty, different lengths,
/// zero or non-finite).
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float? {
    if a.isEmpty || a.count != b.count { return nil }
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for i in a.indices {
        let x = Double(a[i])
        let y = Double(b[i])
        dot += x * y
        normA += x * x
        normB += y * y
    }
    let similarity = dot / (normA.squareRoot() * normB.squareRoot())
    return similarity.isFinite && normA > 0 && normB > 0 ? Float(similarity) : nil
}

/// A song's description vector.
struct EmbeddedSong {
    let songId: Int64
    let vector: [Float]
}

/// Ranks songs against a query vector. Brute force: a phone library is small enough.
enum VybeRanker {
    /// The [limit] songs most similar to [query], best first; equal scores by song id.
    static func rank(_ query: [Float], songs: [EmbeddedSong], limit: Int) -> [VybeMatch] {
        if limit <= 0 { return [] }
        let matches = songs.compactMap { song in cosineSimilarity(query, song.vector).map { VybeMatch(songId: song.songId, score: $0) } }
        return Array(matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.songId < $1.songId }.prefix(limit))
    }
}

/// Songs whose descriptions sit closest to a listener's taste: the weighted centroid of the
/// [seeds]' stored vectors, scored against every other indexed song. Reads stored vectors only.
func tasteNeighbours(_ index: VybeIndexFile, live: [Int64: Int64], seeds: [Int64: Float], limit: Int) -> [VybeMatch] {
    let positive = seeds.filter { $0.value > 0 && $0.value.isFinite }
    if positive.isEmpty || limit <= 0 { return [] }
    let vectors = index.vectorsOf(live: live, wanted: Set(positive.keys))
    guard let size = vectors.values.first?.count else { return [] }
    var centroid = [Float](repeating: 0, count: size)
    var total: Float = 0
    for (id, vector) in vectors.sorted(by: { $0.key < $1.key }) {
        let weight = positive[id]!
        var sum = 0.0
        for x in vector { sum += Double(x) * Double(x) }
        let norm = Float(sum.squareRoot())
        if norm <= 0 { continue }
        for i in centroid.indices { centroid[i] += vector[i] / norm * weight }
        total += weight
    }
    if total <= 0 { return [] }
    return index.rank(live: live, limit: limit) { id, vector in positive[id] != nil ? nil : cosineSimilarity(centroid, vector) }
}
