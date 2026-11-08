import XCTest
import UIKit
@testable import Erhu

final class ToolProgressTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func insert(_ id: Int64, path: String, database: LibraryDatabase) throws {
        try database.db.execute("INSERT INTO albums (id, title, artist, artist_id, song_count, year) VALUES (?, ?, 'Artist', 1, 1, 2026)", [id, "Album \(id)"])
        try database.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, year, date_modified)
            VALUES (?, ?, 'Artist', ?, 1, ?, 180000, ?, ?, 2026, 0)
            """, [id, "Song \(id)", "Album \(id)", id, path, path])
    }
    @MainActor private func wait(_ complete: () -> Bool) async throws {
        for _ in 0..<500 {
            if complete() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Tool operation did not finish")
    }

    @MainActor func testSavedReviewPlansSurviveReopeningAndNewImportsRemainEligible() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: "one.mp3", database: database)
        try insert(2, path: "two.mp3", database: database)
        let library = LibraryStore(database: database)
        let file = root.appendingPathComponent("fix.json")
        let progress = FixTagsProgress(manifest: ProgressFile(url: file))
        let first = try XCTUnwrap(library.songs.first { $0.id == 1 })
        let second = try XCTUnwrap(library.songs.first { $0.id == 2 })
        var request = TagWriteRequest(); request.genre = "Hip Hop"
        let candidate = MetadataCandidate(id: "match", title: first.title, artist: first.artist, album: first.album)
        let diagnostics = RepairDiagnostics(fileName: first.path, identity: TrackIdentity(title: first.title, artist: first.artist, album: first.album), candidates: [candidate])
        try progress.item(1).save(RepairItem(song: first, status: .needsReview, diagnostics: diagnostics,
                                            proposedRequest: request, proposedFields: [.genre, .discNumber]))
        try progress.item(2).save(RepairItem(song: second, status: .done))
        try progress.manifest.save(.init(songs: [first, second], libraryChecked: [1: first.path, 2: second.path],
                                         followsLibrary: true, started: true, autoFillRemaining: [1], scope: [],
                                         missingScanInProgress: false, missingChecked: 2, missingTotal: 2))
        let reopened = FixTagsStore(library: library, checkpointURL: file)
        XCTAssertEqual(reopened.queue.map(\.status), [.needsReview, .done])
        XCTAssertEqual(reopened.queue[0].proposedRequest?.genre, "Hip Hop")
        XCTAssertEqual(reopened.queue[0].proposedFields, [.genre, .discNumber])
        XCTAssertEqual(reopened.queue[0].savedCandidates.map(\.id), ["match"])
        XCTAssertTrue(reopened.isAutoSelectionPaused)
        XCTAssertFalse(reopened.hasWork, "Finished and reviewed tracks must not be silently retried")
        try insert(3, path: "new.mp3", database: database)
        library.reload()
        XCTAssertTrue(reopened.hasWork, "Continue also considers music imported after the saved scan")
    }

    @MainActor func testAnInterruptedTrackRestoresAsPendingWithoutStartingOnlineWork() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: "one.mp3", database: database)
        let library = LibraryStore(database: database)
        let song = try XCTUnwrap(library.songs.first)
        let file = root.appendingPathComponent("fix.json")
        let progress = FixTagsProgress(manifest: ProgressFile(url: file))
        try progress.item(1).save(RepairItem(song: song, status: .fixing))
        try progress.manifest.save(.init(songs: [song], libraryChecked: [:], followsLibrary: false, started: true,
                                         autoFillRemaining: nil, scope: [1], missingScanInProgress: false,
                                         missingChecked: 0, missingTotal: 0))
        let reopened = FixTagsStore(library: library, checkpointURL: file)
        XCTAssertEqual(reopened.queue.first?.status, .pending)
        XCTAssertTrue(reopened.hasWork)
        XCTAssertFalse(reopened.isRunning)
    }

    @MainActor func testRestoredAlbumScopeDoesNotStrandOtherPendingTracksInTheGlobalQueue() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: UUID().uuidString + ".mp3", database: database)
        try insert(2, path: UUID().uuidString + ".mp3", database: database)
        let library = LibraryStore(database: database)
        let songs = library.songs.sorted { $0.id < $1.id }
        let file = root.appendingPathComponent("fix.json")
        let progress = FixTagsProgress(manifest: ProgressFile(url: file))
        try progress.item(1).save(RepairItem(song: songs[0], status: .done))
        try progress.item(2).save(RepairItem(song: songs[1], status: .pending))
        try progress.manifest.save(.init(songs: songs, libraryChecked: [:], followsLibrary: false, started: true,
                                         autoFillRemaining: nil, scope: [1], missingScanInProgress: false,
                                         missingChecked: 0, missingTotal: 0))
        let reopened = FixTagsStore(library: library, checkpointURL: file)
        XCTAssertTrue(reopened.hasWork)
        reopened.start()
        reopened.pause()
        XCTAssertTrue(reopened.inPlaceScope.isEmpty, "The global Continue action processes the global queue; album menu actions still pass an explicit scope")
        try await wait { !reopened.isRunning }
        XCTAssertEqual(reopened.queue[1].status, .pending)
    }

    @MainActor func testACompletedRepairCanStillBeRevertedAfterReopening() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = LibraryPaths.musicFolder.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: audio) }
        let original = TagFixtures.mp3(v4: true)
        try original.write(to: audio)
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: audio.lastPathComponent, database: database)
        let library = LibraryStore(database: database)
        let file = root.appendingPathComponent("fix.json")
        let first = FixTagsStore(library: library, checkpointURL: file)
        first.enqueue(library.songs)
        var request = TagWriteRequest(); request.genre = "Progress test genre"
        try await first.saveManual(request, to: 1, checkedFields: [.genre])
        try await wait { !library.isScanning }
        let reopened = FixTagsStore(library: library, checkpointURL: file)
        defer { reopened.clear() }
        XCTAssertEqual(reopened.queue.first?.status, .done)
        XCTAssertNotNil(reopened.queue.first?.backup)
        await reopened.revert([1])
        try await wait { !library.isScanning }
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }

    @MainActor func testArtworkResumeSkipsUnchangedFilesAndIncludesNewAndChangedAlbums() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let files = (1...3).map { _ in LibraryPaths.musicFolder.appendingPathComponent(UUID().uuidString + ".mp3") }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        for file in files { try Data([1]).write(to: file) }
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: files[0].lastPathComponent, database: database)
        try insert(2, path: files[1].lastPathComponent, database: database)
        let library = LibraryStore(database: database)
        let reads = ArtworkReads()
        let file = root.appendingPathComponent("art.json")
        @MainActor func makeStore() -> ArtworkFetcherStore {
            ArtworkFetcherStore(library: library, service: MetadataService(), checkpointURL: file,
                                artworkPresence: { reads.read($0) })
        }
        let first = makeStore()
        await first.scan()
        XCTAssertEqual(first.checked, 2)
        XCTAssertEqual(reads.count, 2)
        let reopened = makeStore()
        XCTAssertTrue(reopened.hasScanProgress)
        XCTAssertEqual(reopened.checked, 2)
        await reopened.scan()
        XCTAssertEqual(reads.count, 2)
        try insert(3, path: files[2].lastPathComponent, database: database)
        try Data([1, 2]).write(to: files[0])
        library.reload()
        await reopened.scan()
        XCTAssertEqual(reopened.checked, 3)
        XCTAssertEqual(reads.count, 4, "Only the new album and the changed file need another read")
    }

    @MainActor func testResumingAMissingTagCheckKeepsAnUnchangedTracksReviewState() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = LibraryPaths.musicFolder.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: audio) }
        var bytes = TagFixtures.mp3(v4: true)
        if let range = bytes.range(of: Data("TCON".utf8)) { bytes.replaceSubrange(range, with: Data("XCON".utf8)) }
        try bytes.write(to: audio)
        let database = try LibraryDatabase.inMemory()
        try insert(1, path: audio.lastPathComponent, database: database)
        let library = LibraryStore(database: database)
        let song = try XCTUnwrap(library.songs.first)
        let file = root.appendingPathComponent("fix.json")
        let progress = FixTagsProgress(manifest: ProgressFile(url: file))
        try progress.missing(1).save(.init(song: song, stamp: ProgressFileStamp(song), fields: [MetadataField.genre.rawValue], missing: [.genre]))
        try progress.item(1).save(RepairItem(song: song, status: .needsReview, reason: "Reviewed match"))
        try progress.manifest.save(.init(songs: [song], libraryChecked: [1: song.path], followsLibrary: true, started: true,
                                         autoFillRemaining: nil, scope: [], missingScanInProgress: true, missingChecked: 1, missingTotal: 2))
        let reopened = FixTagsStore(library: library, checkpointURL: file)
        let previous = reopened.settings
        defer { reopened.update { $0 = previous } }
        reopened.update { $0.fields = [MetadataField.genre.rawValue] }
        await reopened.findMissingTags()
        XCTAssertEqual(reopened.queue.first?.status, .needsReview)
        XCTAssertEqual(reopened.queue.first?.reason, "Reviewed match")
        XCTAssertEqual(reopened.missingScanProgress?.completed, 1)
        XCTAssertFalse(reopened.hasMissingScanProgress)
    }
}

private final class ArtworkReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return false
    }
}
