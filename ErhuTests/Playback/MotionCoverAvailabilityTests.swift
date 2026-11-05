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

private actor AvailabilityGate {
    var calls = 0
    func enter() { calls += 1 }
}
