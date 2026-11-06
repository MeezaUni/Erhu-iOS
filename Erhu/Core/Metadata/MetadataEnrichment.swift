import Foundation

/// A high scoring search result is not by itself proof that two catalogues describe one recording.
enum MetadataEnrichment {
    static func verified(_ match: MetadataCandidate, candidates: [MetadataCandidate], acceptAt: Float) -> [MetadataCandidate] {
        var seen = Set([match.id])
        return [match] + candidates.filter {
            sameRecording(match, $0) && recordingScore($0, against: match) >= acceptAt && seen.insert($0.id).inserted
        }.sorted {
            let first = sameRelease(match, $0), second = sameRelease(match, $1)
            if first != second { return first }
            return $0.confidenceScore > $1.confidenceScore
        }
    }

    static func sameRecording(_ a: MetadataCandidate, _ b: MetadataCandidate) -> Bool {
        guard isUsableTag(a.title), isUsableTag(b.title), isUsableTag(a.artist), isUsableTag(b.artist),
              identityKey(stripFeaturing(a.title)) == identityKey(stripFeaturing(b.title)),
              identityKey(primaryArtist(a.artist)) == identityKey(primaryArtist(b.artist)) || creditSimilarity(a.artist, b.artist) >= 0.8,
              versionTags(a) == versionTags(b),
              let first = a.durationMs, first > 0, let second = b.durationMs, second > 0
        else { return false }
        // Allow rounding and a short encoder tail, not an edit or an extended recording.
        return abs(first - second) <= max(2_000, min(5_000, min(first, second) / 100))
    }

    static func recordingScore(_ candidate: MetadataCandidate, against anchor: MetadataCandidate) -> Float {
        MetadataScorer.score(candidate, title: anchor.title, artist: anchor.artist, durationMs: anchor.durationMs).confidenceScore
    }

    /// Storefront "- Single"/"- EP" suffixes describe the same release type, not a new edition.
    static func releaseKey(_ title: String) -> String {
        var key = albumPositionTitle(title)
        for suffix in [" - single", " - ep"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)).trimmed }
        return key
    }

    static func sameRelease(_ a: MetadataCandidate, _ b: MetadataCandidate) -> Bool {
        isUsableTag(a.album) && isUsableTag(b.album) && releaseKey(a.album) == releaseKey(b.album) && sameRecording(a, b)
    }

    private static func identityKey(_ text: String) -> String {
        let folded = foldForMatch(text)
        // Symbol-only titles and credits (for example ¥$) must not all collapse to an empty key.
        return folded.isEmpty ? text.lowercased().trimmed : folded
    }

    private static func versionTags(_ candidate: MetadataCandidate) -> Set<String> {
        let text = "\(candidate.title) \(candidate.versionNote ?? "")"
        var tags = LyricsMatcher.tags(text, candidate.album)
        if isSpecialMix(text) { tags.insert("spatial mix") }
        if foldForMatch(text).contains("remaster") {
            tags.insert("remastered")
            for word in foldForMatch(text).split(separator: " ") where word.count == 4 && Int(word) != nil {
                tags.insert("remaster year " + String(word))
            }
        }
        return tags
    }

    static func reportedTempo(_ candidates: [MetadataCandidate]) -> FoundBpm? {
        let values = candidates.filter { $0.sourceName == "Deezer" }.compactMap(\.bpm).filter { plausibleBpm.contains($0) }
        guard let first = values.first, values.allSatisfy({ abs(Double($0 - first)) <= Double(first) * 0.03 }) else { return nil }
        return FoundBpm(bpm: first, source: "Deezer (matched recording)", estimated: true)
    }

    static func releaseDate(_ match: MetadataCandidate, candidates: [MetadataCandidate], acceptAt: Float) -> ReleaseDateDecision {
        let matches = verified(match, candidates: candidates, acceptAt: acceptAt).filter { $0.id == match.id || sameRelease(match, $0) }
        let dates = matches.compactMap { ReleaseDate.parse($0.releaseDate) }
        let years = Set(dates.map(\.year))
        guard years.count <= 1 else { return .rejected("Verified matches disagree on the release year") }
        if let date = ReleaseDate.parse(match.releaseDate) { return .found(date) }
        if let date = dates.first { return .found(date) }
        return .rejected(match.releaseDateIssue ?? "No release date available from the verified matches")
    }
}

/// Inspect the tags themselves, not fallback titles or the scanner's default disc number.
enum MetadataCompleteness {
    static func missing(_ tags: FileTags, fields: Set<MetadataField>) -> [MetadataField] {
        MetadataField.allCases.filter { field in
            guard fields.contains(field) else { return false }
            switch field {
            case .title: return usableIdentityText(tags.title) == nil
            case .artist: return usableIdentityText(tags.artist) == nil
            case .album: return usableIdentityText(tags.album) == nil
            case .year:
                let value = tags.dateText ?? tags.year.map(String.init)
                return !isUsableYearTag(value) || ReleaseDate.parse(value) == nil
            case .genre: return Genres.parse(Genres.join(tags.genres)).isEmpty
            case .bpm: return usableBpm(tags.bpmText) == nil
            case .trackNumber: return !(1...65535).contains(tags.trackNumber ?? 0)
            case .discNumber: return !(1...65535).contains(tags.discNumber ?? 0)
            case .filename: return false
            }
        }
    }

    static func applying(_ request: TagWriteRequest?, to tags: FileTags) -> FileTags {
        guard let request else { return tags }
        var result = tags
        result.title = request.title ?? result.title
        result.artist = request.artist ?? result.artist
        result.album = request.album ?? result.album
        result.dateText = request.releaseDate ?? request.year.map(String.init) ?? result.dateText
        if let genre = request.genre { result.genres = Genres.parse(genre) }
        if let bpm = request.bpm { result.bpmText = String(bpm) }
        result.trackNumber = request.trackNumber ?? result.trackNumber
        result.discNumber = request.discNumber ?? result.discNumber
        return result
    }
}
