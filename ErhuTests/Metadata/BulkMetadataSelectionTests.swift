import XCTest
@testable import Erhu

final class BulkMetadataSelectionTests: XCTestCase {
    private func candidate(_ id: String, score: Float = 0.98, album: String = "Album", duration: Int64? = 180_000) -> MetadataCandidate {
        MetadataCandidate(id: id, title: "Song", artist: "Artist", album: album, durationMs: duration,
                          confidenceScore: score, sourceName: "iTunes")
    }

    private func item(_ candidates: [MetadataCandidate], status: RepairStatus = .needsReview) -> RepairItem {
        let song = Song(id: 1, title: "Song", artist: "Artist", album: "Album", durationMs: 180_000, path: "song.mp3")
        let identity = TrackIdentity(title: "Song", artist: "Artist", album: "Album", durationMs: 180_000)
        return RepairItem(song: song, status: status, diagnostics: RepairDiagnostics(fileName: "song.mp3", identity: identity,
                                                                                  candidates: candidates, topCandidates: Array(candidates.prefix(3))))
    }

    func testExplicitBulkChoiceResolvesTheStrongestAmbiguousCandidate() {
        let choices = [candidate("first", score: 0.96), candidate("best", score: 0.99)]
        XCTAssertEqual(BulkMetadataSelection.best(for: item(choices), minimumConfidence: 0.85)?.id, "best")
    }

    func testEqualScoresPreferTheTaggedAlbumThenTheClosestDuration() {
        let choices = [candidate("other-album", album: "Other Album"), candidate("long", duration: 190_000), candidate("closest")]
        XCTAssertEqual(BulkMetadataSelection.best(for: item(choices), minimumConfidence: 0.85)?.id, "closest")
        XCTAssertEqual(BulkMetadataSelection.best(for: item([candidate("first"), candidate("second")]), minimumConfidence: 0.85)?.id, "first")
    }

    func testThresholdAndCompletedOrRevertedTracksAreRespected() {
        let weak = item([candidate("weak", score: 0.8)])
        XCTAssertNil(BulkMetadataSelection.best(for: weak, minimumConfidence: 0.85))
        XCTAssertNotNil(BulkMetadataSelection.best(for: weak, minimumConfidence: 0.75))
        for status in [RepairStatus.done, .partial, .unchanged, .reverted, .pending, .fixing, .failed, .networkFailed] {
            XCTAssertFalse(BulkMetadataSelection.canSelect(item([candidate("best")], status: status), minimumConfidence: 0.85))
            XCTAssertNil(BulkMetadataSelection.best(for: item([candidate("best")], status: status), minimumConfidence: 0.85))
        }
    }

    func testMissingResultsAndNonFiniteScoresDoNotBecomeAutomaticChoices() {
        XCTAssertNil(BulkMetadataSelection.best(for: item([]), minimumConfidence: 0.85))
        XCTAssertNil(BulkMetadataSelection.best(for: item([candidate("invalid", score: .nan)]), minimumConfidence: 0.85))
    }
}

final class BulkMetadataApplyTests: XCTestCase {
    @MainActor
    func testPendingTrackGetsITunesGenreAndMusicBrainzDiscInOneAutoAction() async throws {
        let database = try LibraryDatabase.inMemory()
        let file = LibraryPaths.musicFolder.appendingPathComponent("fields-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = TagFixtures.mp3(v4: true)
        for (old, new) in [("TCON", "XCON"), ("TPOS", "XPOS")] {
            if let range = data.range(of: Data(old.utf8)) { data.replaceSubrange(range, with: Data(new.utf8)) }
        }
        try data.write(to: file)
        var prepare = TagWriteRequest()
        prepare.title = "(When You Gonna) Give It Up to Me - Radio Version"
        prepare.artist = "Sean Paul & Keyshia Cole"
        prepare.album = "(When You Gonna) Give It Up to Me"
        prepare.trackNumber = 1
        try TagWriter.write(prepare, to: file)
        try database.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, track_number, year, date_modified)
            VALUES (9090, ?, ?, ?, 1, 1, 243000, ?, ?, 1, 2006, 0)
            """, [prepare.title!, prepare.artist!, prepare.album!, file.lastPathComponent, file.lastPathComponent])
        let library = LibraryStore(database: database)
        let store = FixTagsStore(library: library, service: MetadataService(client: MixedFieldsHTTP()))
        let previous = store.settings
        defer { store.update { $0 = previous }; store.clear() }
        store.update { $0.fields = [MetadataField.genre.rawValue, MetadataField.discNumber.rawValue]; $0.source = MetadataSources.musicBrainz }
        store.enqueue(library.songs)
        XCTAssertEqual(store.autoCandidateCount, 1, "Pending tracks without saved candidates must be eligible")
        store.autoSelectBestCandidates()
        try await waitUntil { !store.isRunning && !library.isScanning }
        let tags = TagReader.read(file)
        XCTAssertEqual(Genres.parse(Genres.join(tags.genres)), ["Reggae"])
        XCTAssertEqual(tags.discNumber, 1)
        XCTAssertEqual(store.queue.first?.status, .done)
        XCTAssertTrue(store.queue.first?.notes.contains(where: { $0.contains("Genre from iTunes") }) == true)
        XCTAssertTrue(store.queue.first?.notes.contains(where: { $0.contains("Track/disc numbers from MusicBrainz") }) == true)
    }

    @MainActor
    func testBulkChoiceWritesAllReviewEntriesAndRevertRetainsTheFirstOriginal() async throws {
        let database = try LibraryDatabase.inMemory()
        var files: [URL] = []
        var original = TagFixtures.mp3(v4: true)
        for (old, new) in [("TCON", "XCON"), ("TBPM", "XBPM")] {
            if let range = original.range(of: Data(old.utf8)) { original.replaceSubrange(range, with: Data(new.utf8)) }
        }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        for id in Int64(9001)...9002 {
            let file = LibraryPaths.musicFolder.appendingPathComponent("bulk-\(UUID().uuidString).mp3")
            try original.write(to: file); files.append(file)
            try database.db.execute("""
                INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, track_number, year, date_modified)
                VALUES (?, 'IGOR’S THEME', 'Tyler/ The Creator', 'IGOR', 1, 1, 180000, ?, ?, 3, 2019, 0)
                """, [id, file.lastPathComponent, file.lastPathComponent])
        }
        let library = LibraryStore(database: database)
        let store = FixTagsStore(library: library, service: MetadataService(client: BulkHTTP()))
        let previous = store.settings
        defer { store.update { $0 = previous }; store.clear() }
        store.update { $0.fields = [MetadataField.genre.rawValue]; $0.source = MetadataSources.iTunes; $0.acceptAt = 0.85 }
        store.enqueue(library.songs)
        store.start()
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.queue.map(\.status), [.needsReview, .needsReview])
        XCTAssertEqual(store.autoCandidateCount, 2)

        store.autoSelectBestCandidates()
        try await waitUntil { !store.isRunning && !library.isScanning }
        XCTAssertEqual(store.queue.map(\.status), [.done, .done])
        XCTAssertEqual(store.autoSelectionProgress?.completed, 2)
        for file in files { XCTAssertEqual(Genres.parse(Genres.join(TagReader.read(file).genres)), ["Hip Hop"]) }

        // A later single-track choice must not replace the original backup with the first repair.
        let first = try XCTUnwrap(store.queue.first)
        let alternate = try XCTUnwrap(first.savedCandidates.first { $0.id == "itunes_102" })
        await store.apply(alternate, to: first.id)
        try await waitUntil { !library.isScanning }
        var manual = TagWriteRequest(); manual.bpm = 88
        try await store.saveManual(manual, to: first.id, checkedFields: [.genre, .bpm])
        try await waitUntil { !library.isScanning }
        XCTAssertEqual(TagReader.read(first.song.url).bpmText, "88")
        XCTAssertEqual(store.queue.first?.status, .done)
        await store.revert(Set(store.queue.map(\.id)))
        try await waitUntil { !library.isScanning }
        for file in files { XCTAssertEqual(try Data(contentsOf: file), original) }
    }

    @MainActor private func waitUntil(_ finished: () -> Bool) async throws {
        for _ in 0..<1500 {
            if finished() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Metadata queue did not finish")
    }
}

private struct BulkHTTP: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let body = #"{"results":[{"trackId":101,"trackName":"IGOR’S THEME","artistName":"Tyler, The Creator","collectionName":"IGOR","trackTimeMillis":180000,"primaryGenreName":"Hip Hop"},{"trackId":102,"trackName":"IGOR’S THEME (feat. Someone)","artistName":"Tyler, The Creator","collectionName":"IGOR","trackTimeMillis":180000,"primaryGenreName":"Jazz"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

private struct MixedFieldsHTTP: HTTPClient {
    private let recording = "11111111-1111-4111-8111-111111111111"
    private let release = "33333333-3333-4333-8333-333333333333"
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let body: String
        var code = 200
        if url.host == "itunes.apple.com" {
            body = #"{"results":[{"trackId":186774469,"trackName":"(When You Gonna) Give It Up to Me [Radio Version] [feat. Keyshia Cole]","artistName":"Sean Paul featuring Keyshia Cole","collectionName":"(When You Gonna) Give It Up to Me - Single","trackTimeMillis":243880,"primaryGenreName":"Reggae","trackNumber":1,"discNumber":1}]}"#
        } else if url.path == "/ws/2/recording" {
            body = """
                {"recordings":[{"id":"\(recording)","title":"(When You Gonna) Give It Up to Me - Radio Version","length":243000,"artist-credit":[{"name":"Sean Paul & Keyshia Cole"}],"releases":[{"id":"\(release)","title":"(When You Gonna) Give It Up to Me","status":"Official","release-group":{"id":"22222222-2222-4222-8222-222222222222"}}]}]}
                """
        } else if url.path == "/ws/2/release/" + release {
            body = """
                {"id":"\(release)","title":"(When You Gonna) Give It Up to Me","media":[{"position":1,"tracks":[{"position":1,"recording":{"id":"\(recording)"}}]}]}
                """
        } else if url.host == "musicbrainz.org" { body = #"{"genres":[]}"# }
        else { body = ""; code = 403 }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }
}
