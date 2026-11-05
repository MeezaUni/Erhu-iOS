import XCTest
@testable import Erhu

final class LyricsTimingTests: XCTestCase {
    private let song = Song(id: 7, title: "Song", artist: "Artist", album: "Album", durationMs: 120_000, path: "song.mp3")

    @MainActor
    func testOffsetsSurviveRestartAndRemainSeparateForEachVersionAndSong() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var lyrics = SongLyrics(songId: song.id, text: "[00:01.00]Line", origin: .online, provider: "LRCLIB", sourceID: "LRCLIB:1")
        let first = LyricsTimingContext(song: song, lyrics: lyrics)
        let store = LyricsTimingPreferences(url: url)
        try store.save(1250, for: first)
        lyrics.origin = .onlineSaved
        XCTAssertEqual(first, LyricsTimingContext(song: song, lyrics: lyrics), "Offline copies retain the same timing")
        lyrics.sourceID = "LRCLIB:2"
        let second = LyricsTimingContext(song: song, lyrics: lyrics)
        XCTAssertEqual(store.offset(for: second), 0)
        XCTAssertEqual(store.previous(for: second).first?.offsetMs, 1250)
        try store.save(-500, for: second)
        lyrics = SongLyrics(songId: song.id, text: "[00:02.00]Corrected timestamp", origin: .onlineSaved,
                            provider: "LRCLIB", sourceID: "LRCLIB:2")
        XCTAssertEqual(store.offset(for: LyricsTimingContext(song: song, lyrics: lyrics)), 0, "Changed lyrics form a new version")
        let restored = LyricsTimingPreferences(url: url)
        XCTAssertEqual(restored.offset(for: first), 1250)
        XCTAssertEqual(restored.offset(for: second), -500)
        var another = song; another.path = "other-source.mp3"
        XCTAssertEqual(restored.offset(for: LyricsTimingContext(song: another, lyrics: lyrics)), 0)
    }

    @MainActor
    func testPreviewCancelDoesNotPersistAndFailedSaveDoesNotClaimSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("timing.json")
        let context = LyricsTimingContext(song: song, lyrics: SongLyrics(songId: song.id, text: "[00:01.00]Line"))
        let store = LyricsTimingPreferences(url: url)
        store.preview(900, for: context)
        XCTAssertEqual(store.offset(for: context), 900)
        store.endPreview(for: context)
        XCTAssertEqual(store.offset(for: context), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data().write(to: root)
        XCTAssertThrowsError(try store.save(900, for: context))
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testOffsetSignKeepsHighlightWordsAndLineSeekingConsistent() {
        XCTAssertEqual(LyricsTimingPreferences.lyricsPosition(playbackMs: 5000, offsetMs: 1200), 3800)
        XCTAssertEqual(LyricsTimingPreferences.playbackPosition(lyricMs: 3800, offsetMs: 1200), 5000)
        XCTAssertEqual(LyricsTimingPreferences.lyricsPosition(playbackMs: 5000, offsetMs: -1200), 6200)
        XCTAssertEqual(LyricsTimingPreferences.playbackPosition(lyricMs: 6200, offsetMs: -1200), 5000)
        XCTAssertEqual(LyricsTimingPreferences.playbackPosition(lyricMs: 500, offsetMs: -1200), 0)
    }
}
