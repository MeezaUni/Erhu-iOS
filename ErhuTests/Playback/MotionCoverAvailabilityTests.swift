import XCTest
@testable import Erhu

final class MotionCoverAvailabilityTests: XCTestCase {
    private let albums = (1...3).map { Album(id: Int64($0), title: "Album \($0)", artist: "Artist", artistId: 1, songCount: 2, year: 2025) }

    @MainActor
    func testOnlyFoundCoversAppearAndChangedAlbumTagsInvalidateMatch() async throws {
        let scanner = MotionCoverAvailability(pause: .zero) { album in
            guard album.id == 2 else { return nil }
            return AppleMotionMatch(catalogId: 22, title: album.title, artist: album.artist, storefront: "us", master: URL(string: "https://example.com/cover.m3u8")!)
        }
        scanner.check(albums)
        for _ in 0..<100 {
            if !scanner.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.checking)
        XCTAssertEqual(scanner.checked, 3)
        XCTAssertEqual(scanner.results.count, 1)
        XCTAssertNotNil(scanner.match(for: albums[1]))
        var changed = albums[1]; changed.title = "Different edition"
        XCTAssertNil(scanner.match(for: changed))
    }

    @MainActor
    func testRetryResumesAfterFailureIncludingAlbumsWithoutACover() async throws {
        let history = AvailabilityHistory()
        let scanner = MotionCoverAvailability(pause: .zero) { album in
            try await history.find(album)
        }
        scanner.check(albums)
        for _ in 0..<200 {
            if !scanner.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.checking)
        XCTAssertEqual(scanner.checked, 1)
        scanner.check(albums)
        for _ in 0..<200 {
            if !scanner.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.checking)
        XCTAssertEqual(scanner.checked, 3)
        let requests = await history.requests
        XCTAssertEqual(requests, [1, 2, 2, 3], "A retry must skip completed negative results as well as found covers")
    }

    @MainActor
    func testCheckpointSurvivesRelaunchAndFindsNewAndRenamedAlbums() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = AvailabilityHistory()
        let first = MotionCoverAvailability(pause: .zero, checkpointURL: file) { album in try await history.find(album) }
        first.check(albums)
        for _ in 0..<200 {
            if !first.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(first.checked, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let reopened = MotionCoverAvailability(pause: .zero, checkpointURL: file) { album in try await history.find(album) }
        XCTAssertTrue(reopened.hasChecked)
        XCTAssertEqual(reopened.checked, 1)
        let added = Album(id: 4, title: "New album", artist: "Artist", artistId: 1, songCount: 1, year: 2026)
        XCTAssertEqual(reopened.remaining(in: albums + [added]), 3)
        reopened.check(Array((albums + [added]).reversed()))
        for _ in 0..<200 {
            if !reopened.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.total, 4)
        XCTAssertEqual(reopened.checked, 4)
        let calls = await history.requests
        XCTAssertEqual(calls, [1, 2, 4, 3, 2], "Completed negative results survive restarts and reordering")
        var renamed = albums[0]; renamed.title = "New edition"
        XCTAssertEqual(reopened.remaining(in: [renamed] + Array(albums.dropFirst()) + [added]), 1)
    }

    @MainActor
    func testFoundCoversRestoreButExpiredDownloadURLsAreRefreshed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let scanner = MotionCoverAvailability(pause: .zero, checkpointURL: file) { album in
            AppleMotionMatch(catalogId: 22, title: album.title, artist: album.artist, storefront: "us", master: URL(string: "https://example.com/cover.m3u8")!)
        }
        scanner.check([albums[0]])
        for _ in 0..<100 {
            if !scanner.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(scanner.freshMatch(for: albums[0]))
        let restored = MotionCoverAvailability(checkpointURL: file) { _ in nil }
        XCTAssertEqual(restored.match(for: albums[0]), scanner.match(for: albums[0]))
        XCTAssertNil(restored.freshMatch(for: albums[0]), "A saved availability result must not reuse an expired stream URL for downloading")
        XCTAssertEqual(restored.remaining(in: [albums[0]]), 0)
        restored.check([albums[0]], restart: true)
        for _ in 0..<100 {
            if !restored.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(restored.match(for: albums[0]))
    }

    @MainActor
    func testCancellationPreventsLateResultsAndStopsFurtherLookups() async throws {
        let gate = AvailabilityGate()
        let scanner = MotionCoverAvailability(pause: .zero) { album in
            await gate.enter()
            try await Task.sleep(for: .seconds(10))
            return AppleMotionMatch(catalogId: album.id, title: album.title, artist: album.artist, storefront: "us", master: URL(string: "https://example.com/cover.m3u8")!)
        }
        scanner.check(albums)
        for _ in 0..<100 {
            let count = await gate.calls
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        scanner.cancel()
        for _ in 0..<100 {
            if !scanner.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.checking)
        XCTAssertTrue(scanner.results.isEmpty)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }
}

private actor AvailabilityHistory {
    var requests: [Int64] = []
    func find(_ album: Album) throws -> AppleMotionMatch? {
        requests.append(album.id)
        if requests == [1, 2] { throw URLError(.badServerResponse) }
        return nil
    }
}

private actor AvailabilityGate {
    var calls = 0
    func enter() { calls += 1 }
}
