import Foundation

/// Provider names as stored in settings ("ALL", "iTunes", "MusicBrainz", "Deezer").
enum MetadataSources {
    static let all = "ALL"
    static let iTunes = "iTunes"
    static let musicBrainz = "MusicBrainz"
    static let deezer = "Deezer"

    /// The choices offered for Fix Tags.
    static let options: [(key: String, label: String)] = [
        (all, "Automatic (all sources)"), (iTunes, "iTunes only"), (musicBrainz, "MusicBrainz only"), (deezer, "Deezer only (where available)"),
    ]

    static func matches(_ provider: String, _ selection: String) -> Bool {
        selection.lowercased() == all.lowercased() || provider.lowercased() == selection.lowercased()
    }
}

/// Outcome of a genre lookup for a matched track.
enum GenreLookup: Equatable {
    /// Every usable genre the source lists, most-voted first where it ranks them.
    case found([String], source: String)
    case notFound(String)
    case failed(String)
}

/// Whether a provider may be asked at all this session.
enum ProviderAvailability: Equatable {
    case available
    /// No key in Settings: never called.
    case notConfigured(String)
    /// Its credentials were rejected earlier this session: not called again.
    case rejected(String)
    /// It said earlier this session that it doesn't serve this country: not called again.
    case unavailable(String)
}

/// Searches the metadata providers together, looks up genres and downloads artwork. Providers that
/// can't help for the rest of the session (rejected, not offered here) are remembered, so later
/// tracks get the same truthful status without asking again.
actor MetadataService {
    static let maxArtworkBytes = 10 * 1024 * 1024

    private let client: HTTPClient
    private let iTunes: ITunesProvider
    private let musicBrainz: MusicBrainzProvider
    private let deezer: DeezerProvider
    private let retry: RetryPolicy
    private var unusable: [String: ProviderAvailability] = [:]
    private var deezerDetails: [Int64: DeezerProvider.Track] = [:]
    private var deezerGenres: [Int64: [String]] = [:]

    init(client: HTTPClient = URLSessionHTTPClient(), retry: RetryPolicy = RetryPolicy()) {
        self.client = client
        self.retry = retry
        iTunes = ITunesProvider(client: client)
        musicBrainz = MusicBrainzProvider(client: client)
        deezer = DeezerProvider(client: client)
    }

    private var providers: [MetadataProvider] { [iTunes, musicBrainz, deezer] }

    private func availability(of provider: MetadataProvider) -> ProviderAvailability {
        return unusable[provider.providerName] ?? .available
    }

    /// Forgets this session's provider refusals for an explicit retry.
    func forgetRefusals() {
        unusable = [:]
    }

    /// Only the chosen provider/release supplies ordering. No filename rank or unrelated album is used.
    func withAlbumPosition(_ match: MetadataCandidate) async -> (MetadataCandidate, String?) {
        if AlbumTrackPosition(disc: match.discNumber, track: match.trackNumber).isValid { return (match, nil) }
        var result = match
        do {
            if match.sourceName == "MusicBrainz", let position = try await musicBrainz.albumPosition(match) {
                result.trackNumber = position.track
                result.discNumber = position.disc
            } else if match.sourceName == MetadataSources.iTunes, match.id.hasPrefix("itunes_"),
                      let id = Int64(match.id.dropFirst(7)), id > 0 {
                let response = try await fetchJSON(ITunesProvider.Response.self,
                    requestURL("https://itunes.apple.com/lookup", [("id", String(id)), ("entity", "song")]), client: client)
                if let detail = ITunesProvider.candidates(response).first(where: { $0.id == match.id && $0.releaseId == match.releaseId }),
                   MetadataEnrichment.sameRelease(match, detail) {
                    result.trackNumber = detail.trackNumber
                    result.discNumber = detail.discNumber
                }
            } else if match.sourceName == "Deezer", match.id.hasPrefix("deezer_"),
                      let id = Int64(match.id.dropFirst(7)), id > 0 {
                let detail = try await deezerTrack(id)
                if detail.id == id, detail.album?.id == match.deezerAlbumId,
                   albumPositionTitle(detail.album?.title ?? "") == albumPositionTitle(match.album) {
                    result.trackNumber = detail.trackPosition ?? 0
                    result.discNumber = detail.diskNumber ?? 0
                }
            }
            return (result, nil)
        } catch {
            if match.sourceName == MetadataSources.deezer { rememberDeezerFailure(error) }
            return (result, "Album order lookup failed: \(error.localizedDescription)")
        }
    }

    /// Ordering is a field-level choice, with both numbers from one verified album edition.
    func bestAlbumPosition(_ match: MetadataCandidate, candidates: [MetadataCandidate], acceptAt: Float,
                           localTrack: Int?, localDisc: Int?) async -> (MetadataCandidate, String?) {
        let verified = MetadataEnrichment.verified(match, candidates: candidates, acceptAt: acceptAt)
            .filter { $0.id == match.id || MetadataEnrichment.sameRelease(match, $0) }
        var issues: [String] = []
        for donor in verified {
            let (detail, issue) = await withAlbumPosition(donor)
            if let issue { issues.append(issue) }
            guard AlbumTrackPosition(disc: detail.discNumber, track: detail.trackNumber).isValid else { continue }
            if let localDisc, localDisc > 0, detail.discNumber != localDisc { continue }
            if let localTrack, localTrack > 0, detail.trackNumber != localTrack { continue }
            var positioned = match
            positioned.trackNumber = detail.trackNumber
            positioned.discNumber = detail.discNumber
            return (positioned, "Track/disc numbers from \(detail.sourceName), \(detail.album)")
        }
        var unresolved = match
        unresolved.trackNumber = 0
        unresolved.discNumber = 0
        return (unresolved, issues.first ?? "No verified track/disc pair for this album edition and the existing numbers")
    }

    private func deezerTrack(_ id: Int64) async throws -> DeezerProvider.Track {
        if let cached = deezerDetails[id] { return cached }
        try requireDeezer()
        let response = try await fetchJSON(DeezerProvider.TrackDetail.self, URL(string: "https://api.deezer.com/track/\(id)")!, client: client)
        let detail = response.track
        guard detail.id == id else { throw ProviderError(status: .failed, message: "Deezer returned a different recording") }
        if deezerDetails.count >= 500 { deezerDetails.removeAll() }
        deezerDetails[id] = detail
        return detail
    }

    private func requireDeezer() throws {
        switch unusable[MetadataSources.deezer] ?? .available {
        case .available: break
        case .unavailable(let reason), .rejected(let reason), .notConfigured(let reason):
            throw ProviderError(status: .unavailable, message: reason, sessionWide: true)
        }
    }

    private func rememberDeezerFailure(_ error: Error) {
        let failure = classifyProviderFailure(error)
        if failure.sessionWide || failure.status == .unavailable || failure.status == .authFailed {
            unusable[MetadataSources.deezer] = .unavailable(failure.message)
        }
    }

    /// Search results often omit BPM. Read the matched track's detail, validating its identity again.
    func withReportedTempo(_ match: MetadataCandidate) async -> (MetadataCandidate, String?) {
        guard match.sourceName == MetadataSources.deezer, match.bpm == nil,
              match.id.hasPrefix("deezer_"), let id = Int64(match.id.dropFirst(7)), id > 0 else { return (match, nil) }
        do {
            let detail = try await deezerTrack(id)
            guard let candidate = try DeezerProvider.candidates(.init(data: [detail], total: 1)).first,
                  candidate.deezerAlbumId == match.deezerAlbumId, MetadataEnrichment.sameRecording(match, candidate)
            else { return (match, "Deezer tempo detail did not match this recording and album") }
            var result = match
            result.bpm = candidate.bpm
            return (result, nil)
        } catch {
            rememberDeezerFailure(error)
            return (match, "Deezer tempo lookup: " + classifyProviderFailure(error).message)
        }
    }

    /// Every provider's scored candidates and outcome for one query.
    func search(title: String, artist: String?, album: String?, durationMs: Int64?, selection: String) async -> SearchResponse {
        let list = providers
        let availabilities = list.map { self.availability(of: $0) }
        let retry = retry
        let results = await withTaskGroup(of: (Int, [MetadataCandidate], ProviderOutcome).self) { group in
            for (index, provider) in list.enumerated() {
                group.addTask {
                    let (candidates, outcome) = await Self.searchOne(provider, selection: selection, availability: availabilities[index],
                                                                     title: title, artist: artist, album: album, durationMs: durationMs, retry: retry)
                    return (index, candidates, outcome)
                }
            }
            var collected: [(Int, [MetadataCandidate], ProviderOutcome)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        for (_, _, outcome) in results {
            switch outcome.status {
            case .authFailed: if unusable[outcome.providerName] == nil { unusable[outcome.providerName] = .rejected(outcome.errorMessage ?? "Credentials rejected") }
            case .unavailable: if unusable[outcome.providerName] == nil { unusable[outcome.providerName] = .unavailable(outcome.errorMessage ?? "Not available here") }
            default: break
            }
        }
        let candidates = results.flatMap(\.1).enumerated().sorted { a, b in
            a.element.confidenceScore != b.element.confidenceScore ? a.element.confidenceScore > b.element.confidenceScore : a.offset < b.offset
        }.map(\.element)
        return SearchResponse(candidates: candidates, outcomes: results.map(\.2))
    }

    /// One provider's part of a search: skipped when not selected, not asked again after a
    /// session-wide refusal, else run under [retry] with the failure kept in its real category.
    static func searchOne(_ provider: MetadataProvider, selection: String, availability: ProviderAvailability,
                          title: String, artist: String?, album: String?, durationMs: Int64?,
                          retry: RetryPolicy) async -> ([MetadataCandidate], ProviderOutcome) {
        let name = provider.providerName
        guard MetadataSources.matches(name, selection) else {
            return ([], ProviderOutcome(providerName: name, status: .skipped, errorMessage: "Not selected (source: \(selection))"))
        }
        switch availability {
        case .notConfigured(let reason): return ([], ProviderOutcome(providerName: name, status: .notConfigured, errorMessage: reason))
        case .rejected(let reason): return ([], ProviderOutcome(providerName: name, status: .authFailed, errorMessage: "\(reason) (not retried)"))
        case .unavailable(let reason): return ([], ProviderOutcome(providerName: name, status: .unavailable, errorMessage: "\(reason) (not asked again)"))
        case .available: break
        }
        do {
            let found = try await retry.run { try await provider.searchTrack(title: title, artist: artist, album: album) }
            let scored = found.map { MetadataScorer.score($0, title: title, artist: artist, album: album, durationMs: durationMs) }
            let top = scored.map(\.confidenceScore).max() ?? 0
            let status: ProviderStatus = scored.isEmpty ? .noResults : top >= highConfidenceThreshold ? .success : .lowConfidence
            return (scored, ProviderOutcome(providerName: name, candidateCount: scored.count, status: status))
        } catch {
            // Credentials rejected or not offered here: the caller remembers it for the session.
            let failure = classifyProviderFailure(error)
            return ([], ProviderOutcome(providerName: name, status: failure.status, errorMessage: failure.message))
        }
    }

    /// Enrich fields across verified recordings, even when another provider won the identity match.
    /// MusicBrainz's recording/release genres come first; album and broad catalogue genres are fallbacks.
    func lookupGenre(_ match: MetadataCandidate, candidates: [MetadataCandidate] = [], acceptAt: Float = highConfidenceThreshold) async -> GenreLookup {
        let verified = MetadataEnrichment.verified(match, candidates: candidates, acceptAt: acceptAt)
        var reasons: [String] = []
        var failed = false
        if let brainz = verified.first(where: { $0.sourceName == MetadataSources.musicBrainz }) {
            var found: [MusicBrainzGenre] = []
            if brainz.id.hasPrefix("mb_"), UUID(uuidString: String(brainz.id.dropFirst(3))) != nil {
                do { found += try await musicBrainz.recordingGenres(String(brainz.id.dropFirst(3))) }
                catch { failed = true; reasons.append("MusicBrainz recording: \(classifyProviderFailure(error).message)") }
            }
            if let group = brainz.releaseGroupId, UUID(uuidString: group) != nil,
               brainz.id == match.id || MetadataEnrichment.sameRelease(match, brainz) {
                do { found += try await musicBrainz.releaseGroupGenres(group) }
                catch { failed = true; reasons.append("MusicBrainz album: \(classifyProviderFailure(error).message)") }
            }
            if case .found(let genres, _) = Self.genre(fromMusicBrainz: found) {
                return .found(genres, source: "MusicBrainz recording / album")
            }
            reasons.append("MusicBrainz lists no genre for this recording or album")
        }
        if let deezerMatch = verified.first(where: { $0.deezerAlbumId != nil && ($0.id == match.id || MetadataEnrichment.sameRelease(match, $0)) }), let albumID = deezerMatch.deezerAlbumId {
            do {
                let genres: [String]
                if let cached = deezerGenres[albumID] { genres = cached }
                else {
                    try requireDeezer()
                    genres = Genres.normalize(try await deezer.albumGenres(albumID).map(Optional.init))
                    deezerGenres[albumID] = genres
                }
                if !genres.isEmpty { return .found(genres, source: "Deezer album") }
                reasons.append("Deezer lists no genre for this album")
            } catch {
                rememberDeezerFailure(error)
                failed = true; reasons.append("Deezer: \(classifyProviderFailure(error).message)")
            }
        }
        for candidate in verified {
            let genres = Genres.parse(candidate.genre)
            if !genres.isEmpty { return .found(genres, source: candidate.sourceName + " catalogue") }
        }
        let reason = reasons.isEmpty ? "No genre available from the verified matches" : reasons.joined(separator: "; ")
        return failed ? .failed(reason) : .notFound(reason)
    }

    static func genre(fromMusicBrainz genres: [MusicBrainzGenre]) -> GenreLookup {
        // A genre voted down to zero or below is not one MusicBrainz vouches for. Ties keep MusicBrainz's order.
        let ranked = genres.enumerated().filter { $0.element.count > 0 }
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map { Optional($0.element.name) }
        let usable = Genres.normalize(ranked)
        return usable.isEmpty ? .notFound("MusicBrainz has no genre for this album") : .found(usable, source: "MusicBrainz release group")
    }

    /// Downloads an image for embedding; fails rather than returning a non-image.
    func downloadArtwork(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw ProviderError(status: .failed, message: "Not a valid artwork address") }
        let (data, response) = try await client.get(url, headers: ["User-Agent": metadataUserAgent])
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError(status: .failed, message: "Artwork download failed: HTTP \(response.statusCode)")
        }
        if let type = response.value(forHTTPHeaderField: "Content-Type"), !type.lowercased().hasPrefix("image") {
            throw ProviderError(status: .failed, message: "Artwork address is not an image (\(type))")
        }
        guard !data.isEmpty, data.count <= Self.maxArtworkBytes else { throw ProviderError(status: .failed, message: "Artwork has an invalid size") }
        return data
    }
}
