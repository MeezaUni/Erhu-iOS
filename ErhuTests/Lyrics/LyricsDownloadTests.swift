import XCTest
@testable import Erhu

final class LyricsDownloadTests: XCTestCase {
    private let track = LyricsTrack(songId: 41, query: LyricsQuery(title: "Song", artist: "Artist"))
    private let candidate = LyricsCandidate(provider: "LRCLIB", providerId: 1, trackName: "Song", artistName: "Artist", syncedLyrics: "[00:01.00]A real line")

    func testDownloadsSurviveResponseEvictionAndRemovalDoesNotRemoveTheDisplayedCache() async throws {
        let cache = DownloadMemory(), downloads = DownloadMemory()
        let repository = OnlineLyricsRepository(providers: [], cache: cache, downloads: downloads)
        _ = await repository.choose(track, candidate)
        let automatic = await repository.saved(track)
        XCTAssertNil(automatic, "Choosing/looking up lyrics must not create a download")
        try await repository.download(track, candidate: candidate)
        await cache.remove(track.songId)
        let restored = OnlineLyricsRepository(providers: [], cache: cache, downloads: downloads)
        let saved = await restored.saved(track)
        XCTAssertEqual(saved?.explicitDownload, true)
        guard case .found = await restored.lookup(track) else { return XCTFail("Downloaded lyrics must work without providers") }
        _ = await restored.choose(track, candidate)
        try await restored.removeDownload(track)
        let removed = await restored.saved(track)
        let current = await cache.get(track.songId)
        XCTAssertNil(removed)
        XCTAssertEqual(current?.candidate, candidate)
    }

    func testMetadataChangeDoesNotReuseOrDeleteAnotherRecordingsDownload() async throws {
        let downloads = DownloadMemory()
        let repository = OnlineLyricsRepository(providers: [], cache: DownloadMemory(), downloads: downloads)
        try await repository.download(track, candidate: candidate)
        var changed = track; changed.query.title = "Another recording"
        let saved = await repository.saved(changed)
        XCTAssertNil(saved)
        try await repository.removeDownload(changed)
        let original = await repository.saved(track)
        XCTAssertNotNil(original)
    }

    func testFailedWriteDoesNotClaimLyricsWereDownloaded() async {
        let repository = OnlineLyricsRepository(providers: [], cache: DownloadMemory(), downloads: RefusingDownload())
        do { try await repository.download(track, candidate: candidate); XCTFail("Storage failures must surface") } catch { }
        let saved = await repository.saved(track)
        XCTAssertNil(saved)
    }
}

private actor DownloadMemory: OnlineLyricsCache {
    private var entries: [Int64: CachedLyrics] = [:]
    func get(_ id: Int64) -> CachedLyrics? { entries[id] }
    func put(_ entry: CachedLyrics) { entries[entry.songId] = entry }
    func remove(_ id: Int64) { entries[id] = nil }
}
private actor RefusingDownload: OnlineLyricsCache {
    func get(_ id: Int64) -> CachedLyrics? { nil }
    func put(_ entry: CachedLyrics) { }
    func remove(_ id: Int64) { }
}
