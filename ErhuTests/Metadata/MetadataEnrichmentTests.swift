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

    func testConfirmedSingleDiscCountSuppliesOneButUnknownAndMultiDiscDoNot() throws {
        let json = #"{"results":[{"trackId":1,"trackName":"Song","discCount":1},{"trackId":2,"trackName":"Song","discCount":2},{"trackId":3,"trackName":"Song"}]}"#
        let response = try JSONDecoder().decode(ITunesProvider.Response.self, from: Data(json.utf8))
        XCTAssertEqual(ITunesProvider.candidates(response).map(\.discNumber), [1, 0, 0])
        XCTAssertEqual(MetadataEnrichment.releaseKey("Awaara Angaara - Single"), MetadataEnrichment.releaseKey("Awaara Angaara"))
        XCTAssertEqual(MetadataEnrichment.releaseKey("Album: Part I"), MetadataEnrichment.releaseKey("Album – Part I"))
        XCTAssertNotEqual(MetadataEnrichment.releaseKey("Album (Deluxe)"), MetadataEnrichment.releaseKey("Album"))
    }

    func testDiscOnlyRepairIsNotBlockedByAnUnrelatedExistingTrackNumber() async {
        var donor = brainz(); donor.trackNumber = 2; donor.discNumber = 1
        let (positioned, _) = await MetadataService(client: EnrichmentHTTP(routes: [:])).bestAlbumPosition(
            match(), candidates: [donor], acceptAt: 0.85, localTrack: 639, localDisc: nil, needsTrack: false)
        XCTAssertEqual(positioned.discNumber, 1)
        XCTAssertEqual(positioned.trackNumber, 639)
        let (refused, _) = await MetadataService(client: EnrichmentHTTP(routes: [:])).bestAlbumPosition(
            match(), candidates: [donor], acceptAt: 0.85, localTrack: 639, localDisc: nil)
        XCTAssertEqual(refused.discNumber, 0, "A full ordering repair must still check the pair")
    }

    func testAdditionalITunesGenreSearchRequiresVerifiedRecordingIdentity() async {
        let http = EnrichmentHTTP(routes: ["/search": (200,
            #"{"results":[{"trackId":5,"trackName":"Yellow","artistName":"Coldplay","collectionName":"Greatest Hits","trackTimeMillis":266000,"primaryGenreName":"Alternative"},{"trackId":6,"trackName":"Yellow (Live)","artistName":"Coldplay","trackTimeMillis":266000,"primaryGenreName":"Rock"}]}"#)])
        let result = await MetadataService(client: http).lookupGenre(match())
        XCTAssertEqual(result, .found(["Alternative"], source: "iTunes catalogue (additional verified search)"))
    }

    func testFullMusicBrainzRecordingLookupRecoversTheTaggedAlbumEdition() async {
        let release = "33333333-3333-4333-8333-333333333333"
        let http = EnrichmentHTTP(routes: ["/ws/2/recording/" + recording: (200, """
            {"id":"\(recording)","title":"Yellow","length":266000,"artist-credit":[{"name":"Coldplay"}],
            "releases":[{"id":"\(release)","title":"Parachutes","status":"Official","release-group":{"id":"\(group)"}}]}
            """)])
        var wrongAlbum = brainz(); wrongAlbum.album = "Greatest Hits"
        let recovered = await MetadataService(client: http).matchingAlbum(wrongAlbum, candidates: [], album: "Parachutes", acceptAt: 0.85)
        XCTAssertEqual(recovered?.album, "Parachutes")
        XCTAssertEqual(recovered?.releaseId, release)
    }

    func testWikidataGenreFallbackFollowsTheVerifiedAlbumLink() async {
        let http = EnrichmentHTTP(routes: [
            "/search": (200, #"{"results":[]}"#),
            "/ws/2/recording/" + recording: (200, #"{"genres":[],"relations":[]}"#),
            "/ws/2/release-group/" + group: (200, #"{"genres":[],"relations":[{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q131977"}}]}"#),
            "/wiki/Special:EntityData/Q131977.json": (200, #"{"entities":{"Q131977":{"id":"Q131977","claims":{"P136":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q11366"}}}}]}}}}"#),
            "/w/api.php": (200, #"{"entities":{"Q11366":{"labels":{"en":{"value":"alternative rock"}}}}}"#),
        ])
        let result = await MetadataService(client: http).lookupGenre(brainz())
        XCTAssertEqual(result, .found(["alternative rock"], source: "Wikidata (MusicBrainz-linked album)"))
    }

    func testAmbiguousTemposNeedIndependentClearSectionsAndAMajority() {
        let recovered = TempoEstimator.consensus([.beat(90), .beat(91), .octaveAmbiguous(91, 179), .octaveAmbiguous(179, 90), .noBeat, .noBeat, .noBeat])
        XCTAssertEqual(recovered, .found(bpm: 91, sectionsAgreeing: 4, sections: 7))
        let uncertainExamples: [[TempoEstimator.SectionTempo]] = [
            [.octaveAmbiguous(91, 179), .octaveAmbiguous(179, 91), .octaveAmbiguous(91, 179)],
            [.beat(80), .noBeat, .noBeat],
            [.beat(80), .beat(80), .beat(160), .beat(160), .octaveAmbiguous(80, 160), .noBeat, .noBeat],
            [.beat(151), .beat(100), .noBeat]
        ]
        for results in uncertainExamples {
            guard case .uncertain = TempoEstimator.consensus(results) else { return XCTFail("Unresolved tempo must remain missing") }
        }
    }

    func testExtendedTempoWindowsCoverTheWholeSongWithoutDuplicatingAudio() {
        let rate = 11_025.0
        let starts = TempoAudio.windowStarts(length: Int64(240 * rate), sampleRate: rate)
        XCTAssertEqual(starts.count, 7)
        XCTAssertEqual(starts.first, 0)
        XCTAssertEqual(starts.last, Int64(220 * rate))
        for pair in zip(starts, starts.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, Int64(20 * rate)) }
        XCTAssertEqual(TempoAudio.windowStarts(length: Int64(10 * rate), sampleRate: rate), [0])
    }

    func testWikidataLinkedAlbumGenreRejectsDeprecatedAndConflictingItemsAndCaches() async throws {
        let http = EnrichmentHTTP(routes: [
            "/wiki/Special:EntityData/Q131977.json": (200, """
                {"entities":{"Q131977":{"id":"Q131977","claims":{
                "P436":[{"mainsnak":{"datavalue":{"value":"\(group)"}}}],
                "P136":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q11366"}}}},
                {"rank":"deprecated","mainsnak":{"datavalue":{"value":{"id":"Q999"}}}}]}}}}
                """),
            "/w/api.php": (200, #"{"entities":{"Q11366":{"id":"Q11366","labels":{"en":{"value":"alternative rock"}}}}}"#),
        ])
        let provider = WikidataGenres(client: http)
        for _ in 0..<2 {
            let genres = try await provider.genres(entityID: "Q131977", musicBrainzID: group, property: "P436")
            XCTAssertEqual(genres, ["alternative rock"])
        }
        let wrong = try await provider.genres(entityID: "Q131977", musicBrainzID: recording, property: "P436")
        XCTAssertTrue(wrong.isEmpty)
        let invalid = try await provider.genres(entityID: "../Q131977", musicBrainzID: group, property: "P436")
        XCTAssertTrue(invalid.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testReportedRadioSingleUsesITunesGenreEvenWhenMusicBrainzWonTheMatch() async {
        var anchor = brainz()
        anchor.title = "(When You Gonna) Give It Up to Me - Radio Version"
        anchor.artist = "Sean Paul & Keyshia Cole"
        anchor.album = "(When You Gonna) Give It Up to Me"
        anchor.durationMs = 243_000
        var single = match()
        single.title = "(When You Gonna) Give It Up to Me [Radio Version] [feat. Keyshia Cole]"
        single.artist = "Sean Paul featuring Keyshia Cole"
        single.album = "(When You Gonna) Give It Up to Me - Single"
        single.durationMs = 243_880
        single.genre = "Reggae"
        let http = EnrichmentHTTP(routes: [
            "/ws/2/recording/" + recording: (200, #"{"genres":[]}"#),
            "/ws/2/release-group/" + group: (200, #"{"genres":[]}"#),
        ])
        let result = await MetadataService(client: http).lookupGenre(anchor, candidates: [single])
        XCTAssertEqual(result, .found(["Reggae"], source: "iTunes catalogue"))
    }

    func testReportedAbuYousraGenreMatchesFeaturedArtistInTheITunesTitle() async {
        var anchor = brainz()
        anchor.title = "3 Daqat"; anchor.artist = "Abu, Yousra"; anchor.album = "3 Daqat"; anchor.durationMs = 275_000
        let body = #"{"results":[{"trackId":55,"trackName":"3 Daqat (feat. Yousra)","artistName":"Abu","collectionName":"3 Daqat (feat. Yousra) - Single","trackTimeMillis":275228,"primaryGenreName":"Arabic","discNumber":1,"trackNumber":1}]}"#
        let http = EnrichmentHTTP(routes: [
            "/ws/2/recording/" + recording: (200, #"{"genres":[]}"#),
            "/ws/2/release-group/" + group: (200, #"{"genres":[]}"#),
            "/search": (200, body),
        ])
        let result = await MetadataService(client: http).lookupGenre(anchor)
        XCTAssertEqual(result, .found(["Arabic"], source: "iTunes catalogue (additional verified search)"))
        var cover = anchor; cover.artist = "Another Singer, Yousra"
        XCTAssertFalse(MetadataEnrichment.sameRecording(anchor, cover))
    }

    func testRecordingGenreCanCrossAlbumBoundariesButOrderingCannot() {
        let anchor = match()
        var compilation = match("MusicBrainz", id: "mb_other")
        compilation.album = "Greatest Hits"
        compilation.confidenceScore = 0.7 // Album mismatch lowers the original search score.
        XCTAssertTrue(MetadataEnrichment.sameRecording(anchor, compilation))
        XCTAssertFalse(MetadataEnrichment.sameRelease(anchor, compilation))
        XCTAssertEqual(MetadataEnrichment.verified(anchor, candidates: [compilation], acceptAt: 0.85).count, 2)
    }

    func testAlbumPositionsComeFromAMatchingMusicBrainzReleaseWhenITunesHasNone() async {
        let release = "33333333-3333-4333-8333-333333333333"
        let http = EnrichmentHTTP(routes: [
            "/lookup": (200, #"{"results":[]}"#),
            "/ws/2/release/" + release: (200, """
                {"id":"\(release)","title":"Parachutes","media":[{"position":1,"tracks":[{"position":2,"recording":{"id":"\(recording)"}}]}]}
                """),
        ])
        var donor = brainz(); donor.releaseId = release
        let (positioned, note) = await MetadataService(client: http).bestAlbumPosition(match(), candidates: [donor], acceptAt: 0.85, localTrack: nil, localDisc: nil)
        XCTAssertEqual(positioned.trackNumber, 2)
        XCTAssertEqual(positioned.discNumber, 1)
        XCTAssertTrue(note?.contains("MusicBrainz") == true)
    }

    func testUnrelatedCompilationCannotSupplyTrackAndDiscNumbers() async {
        let http = EnrichmentHTTP(routes: ["/lookup": (200, #"{"results":[]}"#)])
        var compilation = match("Deezer", id: "deezer_8")
        compilation.album = "Greatest Hits"; compilation.trackNumber = 8; compilation.discNumber = 1
        let (positioned, _) = await MetadataService(client: http).bestAlbumPosition(match(), candidates: [compilation], acceptAt: 0.85, localTrack: nil, localDisc: nil)
        XCTAssertEqual(positioned.trackNumber, 0)
        XCTAssertEqual(positioned.discNumber, 0)
    }

    func testRepeatedCountryRefusalDoesNotGrowTheDiagnosticMessage() async {
        let http = EnrichmentHTTP(routes: ["/search": (200, #"{"data":[],"total":14}"#)])
        let service = MetadataService(client: http)
        for _ in 0..<4 {
            let result = await service.search(title: "Song", artist: "Artist", album: "Album", durationMs: nil, selection: MetadataSources.deezer)
            let note = result.outcomes.first { $0.providerName == "Deezer" }?.errorMessage ?? ""
            XCTAssertLessThanOrEqual(note.components(separatedBy: "(not asked again)").count - 1, 1)
        }
        let requests = await http.requests
        XCTAssertEqual(requests, ["/search"])
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
        XCTAssertTrue(MetadataEnrichment.sameRecording(winner, other))
        XCTAssertFalse(MetadataEnrichment.sameRelease(winner, other))
        other = brainz(); other.durationMs = nil
        XCTAssertFalse(MetadataEnrichment.sameRecording(winner, other))
        other = brainz(); other.confidenceScore = 0.5; other.title = "A different song"
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
    func testCompleteTagVerificationRejectsAnOtherwiseValidPartialWriteAtomically() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        var original = TagFixtures.mp3(v4: true)
        if let range = original.range(of: Data("TPOS".utf8)) { original.replaceSubrange(range, with: Data("XPOS".utf8)) }
        try original.write(to: file)
        var request = TagWriteRequest(); request.genre = "Jazz"
        XCTAssertThrowsError(try TagWriter.write(request, to: file, requiringComplete: [.genre, .discNumber]))
        XCTAssertEqual(try Data(contentsOf: file), original)
        request.discNumber = 1
        try TagWriter.write(request, to: file, requiringComplete: [.genre, .discNumber])
        XCTAssertEqual(TagReader.read(file).genres, ["Jazz"])
        XCTAssertEqual(TagReader.read(file).discNumber, 1)
    }
    func testMissingWatermarkedIdentityFieldsAreFilledInsteadOfPreserved() {
        let local = LocalTrackTags(title: "Song", artist: "www.example.com", album: "Unknown Album")
        let candidate = MetadataCandidate(id: "itunes_1", title: "Song", artist: "Artist", album: "Album")
        let plan = FieldFixPlanner.plan(fields: [.artist, .album], fillOnly: true, local: local, match: candidate,
                                        genre: nil, artwork: nil, releaseDate: nil, bpm: nil)
        XCTAssertEqual(plan.request?.artist, "Artist")
        XCTAssertEqual(plan.request?.album, "Album")
    }

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
