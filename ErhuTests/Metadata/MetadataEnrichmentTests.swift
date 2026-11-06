import XCTest
@testable import Erhu

final class MetadataEnrichmentTests: XCTestCase {
    private let recording = "11111111-1111-4111-8111-111111111111"
    private let group = "22222222-2222-4222-8222-222222222222"

    private func match(_ source: String = "iTunes", id: String = "itunes_1") -> MetadataCandidate {
        MetadataCandidate(id: id, title: "Yellow", artist: "Coldplay", album: "Parachutes",
                          durationMs: 266_000, confidenceScore: 0.98, sourceName: source)
    }

    private func brainz() -> MetadataCandidate {
        var value = match("MusicBrainz", id: "mb_" + recording)
        value.releaseGroupId = group
        return value
    }

    func testITunesPrimaryGenreIsDecoded() throws {
        let data = Data(#"{"results":[{"trackId":1,"trackName":"Yellow","artistName":"Coldplay","collectionName":"Parachutes","primaryGenreName":"Alternative"}]}"#.utf8)
        let response = try JSONDecoder().decode(ITunesProvider.Response.self, from: data)
        XCTAssertEqual(ITunesProvider.candidates(response).first?.genre, "Alternative")
    }

    func testITunesWinnerGetsAllUsableMusicBrainzRecordingAndAlbumGenres() async throws {
        let http = EnrichmentHTTP(routes: [
            "/ws/2/recording/" + recording: (200, #"{"genres":[{"name":"alternative rock","count":8},{"name":"unknown","count":9}]}"#),
            "/ws/2/release-group/" + group: (200, #"{"genres":[{"name":"rock","count":6},{"name":"Alternative Rock","count":3},{"name":"pop","count":0}]}"#),
        ])
        let service = MetadataService(client: http)
        let result = await service.lookupGenre(match(), candidates: [brainz()])
        XCTAssertEqual(result, .found(["alternative rock", "rock"], source: "MusicBrainz recording / album"))
    }

    func testMissingMusicBrainzGenresFallBackToDeezerAndCacheAlbumLookup() async {
        let http = EnrichmentHTTP(routes: [
            "/ws/2/recording/" + recording: (200, #"{"genres":[]}"#),
            "/ws/2/release-group/" + group: (200, #"{"genres":[]}"#),
            "/album/42": (200, #"{"genres":{"data":[{"id":1,"name":"Alternative"},{"id":2,"name":"Rock"}]}}"#),
        ])
        var deezer = match("Deezer", id: "deezer_8")
        deezer.deezerAlbumId = 42
        let service = MetadataService(client: http)
        for _ in 0..<2 {
            let result = await service.lookupGenre(match(), candidates: [brainz(), deezer])
            XCTAssertEqual(result, .found(["Alternative", "Rock"], source: "Deezer album"))
        }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0 == "/album/42" }.count, 1)
    }

    func testProviderFailureStillUsesITunesGenre() async {
        let http = EnrichmentHTTP(routes: [
            "/ws/2/recording/" + recording: (503, ""),
            "/ws/2/release-group/" + group: (503, ""),
        ])
        var winner = match()
        winner.genre = "Alternative"
        let result = await MetadataService(client: http).lookupGenre(winner, candidates: [brainz()])
        XCTAssertEqual(result, .found(["Alternative"], source: "iTunes catalogue"))
    }

    func testUnverifiedRecordingsCannotContributeFieldsOrMakeNetworkRequests() async {
        let http = EnrichmentHTTP(routes: [:])
        var different = brainz()
        different.durationMs = 300_000
        var winner = match()
        winner.genre = "Alternative"
        let result = await MetadataService(client: http).lookupGenre(winner, candidates: [different])
        XCTAssertEqual(result, .found(["Alternative"], source: "iTunes catalogue"))
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testIdentityCheckRejectsVersionsOtherAlbumsUnknownDurationAndLowConfidence() {
        let winner = match()
        var other = brainz()
        XCTAssertTrue(MetadataEnrichment.sameRecording(winner, other))
        other.versionNote = "live"
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other.versionNote = "2011 remaster"
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other.versionNote = "clean"
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other.versionNote = nil
        other.album = "Parachutes (Deluxe)"
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other = brainz(); other.durationMs = nil
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other = brainz(); other.confidenceScore = 0.5
        XCTAssertEqual(MetadataEnrichment.verified(winner, candidates: [other], acceptAt: 0.85), [winner])
    }

    func testSymbolOnlyNamesDoNotCollapseIntoTheSameRecording() {
        var first = match(); first.title = "!"; first.artist = "¥$"
        var second = first; second.title = "?"
        XCTAssertFalse(MetadataEnrichment.sameRecording(first, second))
        second = first; second.artist = "$"
        XCTAssertFalse(MetadataEnrichment.sameRecording(first, second))
    }

    func testDeezerTempoDetailUsesTheSameRecordingAndAlbum() async {
        let http = EnrichmentHTTP(routes: ["/track/8": (200, #"{"id":8,"title":"Yellow","duration":266,"bpm":87,"artist":{"id":1,"name":"Coldplay"},"album":{"id":42,"title":"Parachutes"}}"#)])
        var deezer = match("Deezer", id: "deezer_8")
        deezer.deezerAlbumId = 42
        let (enriched, issue) = await MetadataService(client: http).withReportedTempo(deezer)
        XCTAssertNil(issue)
        XCTAssertEqual(enriched.bpm, 87)
        let tempo = MetadataEnrichment.reportedTempo([enriched])
        XCTAssertEqual(tempo?.bpm, 87)
        XCTAssertEqual(tempo?.estimated, true)
    }

    func testConflictingProviderTemposDoNotChooseAnArbitraryOctave() {
        var first = match("Deezer", id: "deezer_8"); first.bpm = 80
        var second = first; second.id = "deezer_9"; second.bpm = 160
        XCTAssertNil(MetadataEnrichment.reportedTempo([first, second]))
    }

    func testDeezerRegionRefusalDoesNotBlockOtherProvidersOrRetryForEachField() async {
        for refusal in [(403, ""), (200, #"{"error":{"message":"Service is not available in your country"}}"#)] {
            let http = EnrichmentHTTP(routes: ["/track/8": refusal])
            let service = MetadataService(client: http)
            var deezer = match("Deezer", id: "deezer_8"); deezer.deezerAlbumId = 42
            _ = await service.withReportedTempo(deezer)
            _ = await service.withReportedTempo(deezer)
            var winner = match(); winner.genre = "Alternative"
            let result = await service.lookupGenre(winner, candidates: [deezer])
            XCTAssertEqual(result, .found(["Alternative"], source: "iTunes catalogue"))
            let requests = await http.requests
            XCTAssertEqual(requests, ["/track/8"])
        }
    }

    func testReleaseDateCanComeFromAVerifiedProviderButConflictingYearsNeedReview() {
        let winner = match()
        var donor = brainz(); donor.releaseDate = "2000-07-10"
        XCTAssertEqual(MetadataEnrichment.releaseDate(winner, candidates: [donor], acceptAt: 0.85),
                       .found(ReleaseDate.parse("2000-07-10")!))
        var other = match("Deezer", id: "deezer_8"); other.releaseDate = "2011-01-01"
        guard case .rejected = MetadataEnrichment.releaseDate(winner, candidates: [donor, other], acceptAt: 0.85) else {
            return XCTFail("Conflicting release editions must not supply an arbitrary year")
        }
    }
}

private actor EnrichmentHTTP: HTTPClient {
    let routes: [String: (Int, String)]
    private(set) var requests: [String] = []
    init(routes: [String: (Int, String)]) { self.routes = routes }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        requests.append(url.path)
        let (code, body) = routes[url.path] ?? (404, "")
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }
}

final class MetadataCompletenessTests: XCTestCase {
    func testEverySelectedMissingFieldIsReportedEvenWhenCoreIdentityIsPresent() {
        let tags = FileTags(title: "Yellow", artist: "Coldplay", album: "Parachutes")
        XCTAssertEqual(MetadataCompleteness.missing(tags, fields: Set(MetadataField.allCases)), [.year, .genre, .bpm, .trackNumber, .discNumber])
        XCTAssertEqual(MetadataCompleteness.missing(tags, fields: [.genre]), [.genre])
        XCTAssertTrue(MetadataCompleteness.missing(tags, fields: [.title, .artist, .album]).isEmpty)
    }

    func testPlaceholderGenreInvalidYearAndBpmAreMissing() {
        let tags = FileTags(dateText: "9999", genres: ["Unknown", "none"], bpmText: "0")
        XCTAssertEqual(MetadataCompleteness.missing(tags, fields: [.year, .genre, .bpm]), [.year, .genre, .bpm])
    }

    func testActualFileRoundTripFillsGenreAndRetainsIdentityAndValidBpm() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try TagFixtures.mp3(v4: true).write(to: file)
        var clear = TagWriteRequest(); clear.clearGenre = true
        try TagWriter.write(clear, to: file)
        let before = TagReader.read(file)
        XCTAssertEqual(MetadataCompleteness.missing(before, fields: [.genre, .bpm]), [.genre])
        var edit = TagWriteRequest(); edit.genre = "Hip Hop; Neo Soul"
        try TagWriter.write(edit, to: file)
        let after = TagReader.read(file)
        XCTAssertEqual(MetadataCompleteness.missing(after, fields: [.genre, .bpm]), [])
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.artist, before.artist)
        XCTAssertEqual(after.album, before.album)
        XCTAssertEqual(Genres.parse(Genres.join(after.genres)), ["Hip Hop", "Neo Soul"])
        XCTAssertEqual(after.bpmText, before.bpmText)
    }
}
