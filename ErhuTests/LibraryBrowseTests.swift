import XCTest
@testable import Erhu

final class LibraryBrowseTests: XCTestCase {
    private func song(_ id: Int64, title: String = "Song", album: Int64 = 1, genre: String? = nil, bpm: Int? = nil) -> Song {
        Song(id: id, title: title, artist: "Artist", album: "Album \(album)", albumId: album,
             durationMs: 180_000, path: "\(id).mp3", genre: genre, bpm: bpm)
    }

    func testSongOrdersUseImportAndPlaybackHistoryWithDeterministicTies() {
        let songs = [song(1, title: "10"), song(2, title: "2"), song(3, title: "Alpha")]
        let facts: [Int64: LibraryBrowseFact] = [1: .init(addedAt: 30, lastPlayedAt: 10, plays: 2),
                                               2: .init(addedAt: 20, lastPlayedAt: 40, plays: 1)]
        var request = SongBrowseRequest(songs: songs, facts: facts, query: "", sort: .title)
        XCTAssertEqual(request.results().map(\.id), [2, 1, 3])
        request.sort = .titleDescending
        XCTAssertEqual(request.results().map(\.id), [3, 1, 2])
        request.sort = .recentlyAdded
        XCTAssertEqual(request.results().map(\.id), [1, 2, 3])
        request.sort = .recentlyPlayed
        XCTAssertEqual(request.results().map(\.id), [2, 1, 3])
        request.sort = .mostPlayed
        XCTAssertEqual(request.results().map(\.id), [1, 2, 3])
        XCTAssertEqual(request.results(), request.results())
    }

    func testGenreMoodAndQueryIntersectWithoutInventingMoodForUntaggedSongs() {
        let songs = [song(1, title: "Quiet Night", genre: "Jazz; R&B", bpm: 90),
                     song(2, title: "Night Dance", genre: "Dance; R&B", bpm: 130),
                     song(3, title: "Night"), song(4, title: "Morning", genre: "jazz", bpm: 90)]
        var request = SongBrowseRequest(songs: songs, facts: [:], query: "night", sort: .title,
                                        genre: SectionSearch.key("R&B"), mood: .lateNight)
        XCTAssertEqual(request.results().map(\.id), [1])
        request.mood = .highEnergy
        XCTAssertEqual(request.results().map(\.id), [2])
        request.genre = LibraryBrowse.untaggedGenre
        XCTAssertTrue(request.results().isEmpty)
        request.mood = .all
        XCTAssertEqual(request.results().map(\.id), [3])
        XCTAssertEqual(LibraryBrowse.genres(in: songs), ["Dance", "Jazz", "R&B"])
    }

    func testSearchKeepsUnicodeAndIsScopedToTheProvidedCollection() {
        let songs = [song(1, title: "कल चौदहवीं की रात थी"), song(2, title: "مرحبا"),
                     song(3, title: "Beyoncé"), song(4, title: "$ome $exy $ongs")]
        var request = SongBrowseRequest(songs: songs, facts: [:], query: "चौदहवीं", sort: .title)
        XCTAssertEqual(request.results().map(\.id), [1])
        request.query = "مرحبا"
        XCTAssertEqual(request.results().map(\.id), [2])
        request.query = "beyonce"
        XCTAssertEqual(request.results().map(\.id), [3])
        request.query = "some sexy"
        XCTAssertEqual(request.results().map(\.id), [4])
        request.query = "missing"
        XCTAssertTrue(request.results().isEmpty)
        request.songs = [songs[0]]
        request.query = "beyonce"
        XCTAssertTrue(request.results().isEmpty)
    }

    func testAlbumsAggregateTracksAndKeepUnknownYearsLast() {
        let albums = [Album(id: 1, title: "Alpha", artist: "B", artistId: 1, songCount: 2, year: 2020),
                      Album(id: 2, title: "Beta", artist: "A", artistId: 2, songCount: 1, year: 1990),
                      Album(id: 3, title: "Gamma", artist: "C", artistId: 3, songCount: 1, year: 0)]
        let songs = [song(1), song(2), song(3, album: 2)]
        let facts: [Int64: LibraryBrowseFact] = [1: .init(addedAt: 10, lastPlayedAt: 20, plays: 2),
                                               2: .init(addedAt: 40, plays: 3), 3: .init(addedAt: 30, plays: 4)]
        var request = AlbumBrowseRequest(albums: albums, songs: songs, facts: facts, lastPlayed: [2: 80], query: "", sort: .recentlyAdded)
        XCTAssertEqual(request.results().map(\.id), [1, 2, 3])
        request.sort = .recentlyPlayed
        XCTAssertEqual(request.results().map(\.id), [2, 1, 3])
        request.sort = .mostPlayed
        XCTAssertEqual(request.results().map(\.id), [1, 2, 3])
        request.sort = .oldestYear
        XCTAssertEqual(request.results().map(\.id), [2, 1, 3])
        request.sort = .newestYear
        XCTAssertEqual(request.results().map(\.id), [1, 2, 3])
        request.sort = .artist
        XCTAssertEqual(request.results().map(\.id), [2, 1, 3])
        request.query = "beta a"
        XCTAssertEqual(request.results().map(\.id), [2])
    }

    func testPullThresholdUsesAdjustedTopInsetAndRejectsOrdinaryScroll() {
        XCTAssertFalse(LibrarySearchReveal.shouldReveal(offset: -144, topInset: 144))
        XCTAssertFalse(LibrarySearchReveal.shouldReveal(offset: -170, topInset: 144))
        XCTAssertTrue(LibrarySearchReveal.shouldReveal(offset: -180, topInset: 144))
        XCTAssertFalse(LibrarySearchReveal.shouldReveal(offset: 300, topInset: 144))
        XCTAssertFalse(LibrarySearchReveal.shouldReveal(offset: .nan, topInset: 0))
    }
}

final class LibraryBrowseHistoryTests: XCTestCase {
    private func insert(_ database: LibraryDatabase, id: Int64, modified: Int64) throws {
        try database.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, track_number, year, date_modified)
            VALUES (?, 'Song', 'Artist', 'Album', 1, 7, 180000, 'song.mp3', 'song.mp3', 1, 2020, ?)
            """, [id, modified])
    }

    func testVersionOneMigrationBackfillsImportDateOnce() throws {
        let sqlite = try SQLiteDatabase.inMemory()
        var database = try LibraryDatabase(db: sqlite)
        try insert(database, id: 1, modified: 123)
        try sqlite.execute("DROP TABLE library_imports")
        try sqlite.execute("PRAGMA user_version = 1")
        database = try LibraryDatabase(db: sqlite)
        XCTAssertEqual(sqlite.userVersion, 2)
        XCTAssertEqual(try database.libraryBrowseFacts()[1]?.addedAt, 123)
        try sqlite.execute("UPDATE songs SET date_modified = 999 WHERE id = 1")
        database = try LibraryDatabase(db: sqlite)
        XCTAssertEqual(try database.libraryBrowseFacts()[1]?.addedAt, 123)
    }

    func testPlaybackStartChangesRecentOrderWithoutCountingAPlay() throws {
        let database = try LibraryDatabase.inMemory()
        try insert(database, id: 1, modified: 123)
        try database.recordAlbumOfSongPlayed(1, at: 500)
        XCTAssertEqual(try database.libraryBrowseFacts()[1]?.lastPlayedAt, 500)
        XCTAssertEqual(try database.libraryBrowseFacts()[1]?.plays, 0)
        XCTAssertEqual(try database.albumPlaybackTimes()[7], 500)
        try database.recordAlbumOfSongPlayed(999, at: 600)
        XCTAssertNil(try database.libraryBrowseFacts()[999])
        XCTAssertEqual(try database.albumPlaybackTimes()[7], 500)
    }

    func testRescanAndRetagPreserveImportDateAndRemovalDropsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("song.mp3")
        try TagFixtures.mp3(v4: true).write(to: file)
        let database = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: database, folder: folder)
        _ = try scanner.scan()
        let id = try XCTUnwrap(database.allSongs().first?.id)
        try database.db.execute("UPDATE library_imports SET added_at = 123 WHERE song_id = ?", [id])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 456)], ofItemAtPath: file.path)
        _ = try scanner.scan()
        XCTAssertEqual(try database.libraryBrowseFacts()[id]?.addedAt, 123)
        try FileManager.default.removeItem(at: file)
        _ = try scanner.scan()
        let imports = try database.db.query("SELECT song_id FROM library_imports") { $0.int64("song_id") }
        XCTAssertTrue(imports.isEmpty)
        try TagFixtures.mp3(v4: true).write(to: file)
        _ = try scanner.scan()
        XCTAssertGreaterThan(try XCTUnwrap(database.libraryBrowseFacts()[id]?.addedAt), 123)
    }
}
