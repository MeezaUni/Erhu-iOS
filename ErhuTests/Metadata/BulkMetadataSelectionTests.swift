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
    func testBulkChoiceWritesAllReviewEntriesAndRevertRetainsTheFirstOriginal() async throws {
        let database = try LibraryDatabase.inMemory()
        var files: [URL] = []
        let original = TagFixtures.mp3(v4: true)
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
