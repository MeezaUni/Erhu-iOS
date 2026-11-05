import XCTest
@testable import Erhu

final class MotionCoverDownloadsTests: XCTestCase {
    private let albums = (1...4).map { Album(id: Int64($0), title: "Album \($0)", artist: "Artist", artistId: 1, songCount: 2, year: 2025) }

    @MainActor
    func testSelectionSkipsSavedUnavailableAndDuplicateAlbums() async {
        let input = [albums[2], albums[0], albums[1], albums[2], albums[3]]
        let pending = MotionCoverDownloads.pending(input, available: [1, 2, 3], downloaded: [1])
        XCTAssertEqual(pending.map(\.id), [3, 2])
    }

    @MainActor
    func testDownloadsAreSerialAndOneFailureDoesNotDiscardOtherCovers() async throws {
        let queue = MotionCoverDownloads()
        defer { queue.stop() }
        var active = 0, maximum = 0
        var calls: [Int64] = []
        queue.start(albums) { album in
            active += 1; maximum = max(active, maximum); calls.append(album.id)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            if album.id == 2 { throw URLError(.cannotConnectToHost) }
            return album.id == 3 ? .unavailable : .saved
        }
        try await waitUntil { !queue.isRunning }
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(calls, [1, 2, 3, 4])
        XCTAssertEqual(queue.completed, 4)
        XCTAssertEqual(queue.saved, 2)
        XCTAssertEqual(queue.failed, 1)
        XCTAssertEqual(queue.unavailable, 1)
    }

    @MainActor
    func testStopKeepsCompletedWorkAndResumeSkipsIt() async throws {
        let queue = MotionCoverDownloads()
        defer { queue.stop() }
        var calls: [Int64] = []
        queue.start(Array(albums.prefix(3))) { album in
            calls.append(album.id)
            if album.id == 2 { try await Task.sleep(for: .seconds(30)) }
            return .saved
        }
        try await waitUntil { queue.current?.id == 2 }
        queue.stop()
        queue.start([albums[3]]) { album in calls.append(album.id); return .saved }
        try await waitUntil { !queue.isRunning }
        XCTAssertEqual(calls, [1, 2], "A replacement must wait for cancellation and file cleanup to finish")
        XCTAssertEqual(queue.saved, 1)
        XCTAssertEqual(queue.completed, 1)
        let remaining = MotionCoverDownloads.pending(Array(albums.prefix(3)), available: [1, 2, 3], downloaded: [1])
        queue.start(remaining) { album in calls.append(album.id); return .saved }
        try await waitUntil { !queue.isRunning }
        XCTAssertEqual(calls, [1, 2, 2, 3])
        XCTAssertEqual(queue.saved, 2)
    }

    @MainActor
    func testCancellationAfterACommitCountsThatCoverAndNeverStartsTheNext() async throws {
        let queue = MotionCoverDownloads()
        defer { queue.stop() }
        var calls: [Int64] = []
        queue.start(albums) { album in
            calls.append(album.id)
            queue.stop() // Simulate a stop arriving as this cover has finished committing.
            return .saved
        }
        try await waitUntil { !queue.isRunning }
        XCTAssertEqual(calls, [1])
        XCTAssertEqual(queue.saved, 1)
        XCTAssertEqual(queue.completed, 1)
    }

    @MainActor
    func testFullStorageStopsTheBatchWithoutStartingMoreDownloads() async throws {
        let queue = MotionCoverDownloads()
        defer { queue.stop() }
        var calls: [Int64] = []
        queue.start(albums) { album in
            calls.append(album.id)
            if album.id == 2 { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
            return .saved
        }
        try await waitUntil { !queue.isRunning }
        XCTAssertEqual(calls, [1, 2])
        XCTAssertEqual(queue.saved, 1)
        XCTAssertEqual(queue.failed, 1)
        XCTAssertTrue(queue.message?.contains("Storage is full") == true)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The download worker must finish or cancel promptly")
    }
}
