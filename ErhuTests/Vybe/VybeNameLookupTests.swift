import Foundation
import os
import XCTest
@testable import Erhu

private struct NameTestEmbedder: TextEmbedder, Sendable {
    let modelId = "name-lookup-test"
    let dimension = 3
    let weakBest: Float = 0.3
    var calls = OSAllocatedUnfairLock(initialState: 0)
    func embed(_ text: String, role: EmbeddingRole) throws -> [Float] {
        guard role == .document else { throw NSError(domain: "Name search must not embed the query", code: 1) }
        calls.withLock { $0 += 1 }
        return [1, 0, 0]
    }
}

private struct NameTestVectors: SongVectors {
    let ids: [Int64]
    func vectorOf(_ songId: Int64) -> [Float]? { ids.contains(songId) ? [1, 0, 0] : nil }
    func rank(limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch] {
        Array(ids.compactMap { id in score(id, [1, 0, 0]).map { VybeMatch(songId: id, score: $0) } }.prefix(limit))
    }
}

final class VybeNameLookupTests: XCTestCase {
    private let library = [
        SongText(songId: 1, title: "Bound 2", artist: "Ye", album: "Yeezus", genre: "Hip-Hop", bpm: 80),
        SongText(songId: 2, title: "Black Skinhead", artist: "Ye", album: "Yeezus", genre: "Hip-Hop", bpm: 130),
        SongText(songId: 3, title: "Runaway", artist: "Kanye West feat. Pusha T", album: "My Beautiful Dark Twisted Fantasy", genre: "Hip-Hop", bpm: 87),
        SongText(songId: 4, title: "Snooze", artist: "SZA", album: "SOS", genre: "R&B", bpm: 72),
        SongText(songId: 5, title: "Till It's Gone", artist: "Yelawolf", album: "Love Story", genre: "Hip-Hop", bpm: 100),
    ]

    private func discovery(_ songs: [SongText]) -> VybeDiscovery {
        VybeDiscovery(embedder: NameTestEmbedder(), vectors: NameTestVectors(ids: songs.map(\.songId)), names: VybeNameIndex(songs: songs))
    }

    func testLikeBoundUsesBound2AsItsSeedWithoutEmbeddingTheName() throws {
        guard case .named(.title, let name, let ids, let similar) = try discovery(library).search("like bound", songs: library, limit: 5) else {
            return XCTFail("A shortened library title must not become an unknown-name description")
        }
        XCTAssertEqual(name, "Bound 2")
        XCTAssertEqual(ids, [1])
        XCTAssertEqual(Set(similar.map(\.songId)), [2, 3, 4, 5])
    }

    func testKanyeFindsYeAndAliasesWorkInBothDirections() throws {
        let index = VybeNameIndex(songs: library)
        for query in ["Kanye", "Kanye West", "Ye", "songs by Kanye", "in kanye"] {
            guard case .named(.artist, _, let ids, _) = VybeQueryRouter.route(query, index: index) else { return XCTFail(query) }
            XCTAssertEqual(ids, [1, 2, 3], query)
            XCTAssertFalse(ids.contains(5), "Ye must not match a fragment of Yelawolf")
        }
        let onlyWest = [library[2]]
        guard case .named(.artist, _, let ids, _) = VybeQueryRouter.route("Ye", songs: onlyWest) else { return XCTFail("reverse alias") }
        XCTAssertEqual(ids, [3])
        let boosts = VybeDiscovery.metadataBoosts("chill Kanye vibes", songs: library, names: index)
        XCTAssertTrue(boosts[1]?.contains { $0.0 == "Artist: Ye" } == true)
        XCTAssertFalse(MusicQueryIntent("chill music without Kanye", songs: library).allows(library[0]))
    }

    func testWordsPrefixesSmallTyposAndAlbumWordOrder() {
        for query in ["like bou", "like boudn", "like BOUND", "like Bound2", "bound"] {
            guard case .named(.title, let name, let ids, _) = VybeQueryRouter.route(query, songs: library) else { return XCTFail(query) }
            XCTAssertEqual(name, "Bound 2"); XCTAssertEqual(ids, [1])
        }
        for query in ["albums like beautiful fantasy", "albums like fantasy beautiful"] {
            guard case .named(.album, let name, let ids, _) = VybeQueryRouter.route(query, songs: library) else { return XCTFail(query) }
            XCTAssertEqual(name, "My Beautiful Dark Twisted Fantasy"); XCTAssertEqual(ids, [3])
        }
        guard case .unknownName = VybeQueryRouter.route("like bound 3", songs: library) else { return XCTFail("Numbers must stay exact") }
        guard case .unknownName = VybeQueryRouter.route("like bound3", songs: library) else { return XCTFail("Do not remove numeric suffixes as typos") }
        guard case .unknownName = VybeQueryRouter.route("like unbound", songs: library) else { return XCTFail("No arbitrary substring matching") }
    }

    func testAmbiguousNamesOfferChoicesAndSelectingOneKeepsFilters() throws {
        let songs = library + [SongText(songId: 6, title: "Bound for Glory", artist: "Another Artist", album: "Road", bpm: 140)]
        let search = discovery(songs)
        guard case .ambiguous(let query, let choices, let similar) = try search.search("like bound", songs: songs, limit: 5) else {
            return XCTFail("Both titles should be offered instead of guessed")
        }
        XCTAssertEqual(Set(choices.map(\.name)), ["Bound 2", "Bound for Glory"])
        XCTAssertEqual(query, "like bound"); XCTAssertTrue(similar)
        let selected = try XCTUnwrap(choices.first { $0.name == "Bound 2" })
        guard case .named(.title, _, let ids, let hits) = search.select(selected, query: "like bound under 100 BPM", songs: songs, wantsSimilar: true, limit: 5) else {
            return XCTFail("not selected")
        }
        XCTAssertEqual(ids, [1]); XCTAssertEqual(Set(hits.map(\.songId)), [3, 4])
    }

    func testExactNamesAndShortAliasesDoNotBecomeUnsafeFragments() {
        let songs = library + [SongText(songId: 6, title: "Bound", artist: "Other", album: ""), SongText(songId: 7, title: "Snow", artist: "Other", album: "")]
        guard case .named(.title, let name, let ids, _) = VybeQueryRouter.route("like bound", songs: songs) else { return XCTFail("exact title") }
        XCTAssertEqual(name, "Bound"); XCTAssertEqual(ids, [6])
        XCTAssertEqual(VybeQueryRouter.route("slow", songs: songs), .describe(query: "slow"), "Do not correct a mood into Snow")
        XCTAssertEqual(VybeQueryRouter.route("late night music", songs: songs), .describe(query: "late night music"))
        guard case .unknownName = VybeQueryRouter.route("songs by We", songs: library) else { return XCTFail("short partial") }
    }

    func testExistingApprovedAliasesAreAvailableWithoutChangingTags() {
        let songs = [SongText(songId: 1, title: "Song", artist: "Stage Name", album: "Album")]
        let index = VybeNameIndex(songs: songs, aliases: ["legal name": "stage name"])
        guard case .named(.artist, let name, let ids, _) = VybeQueryRouter.route("Legal Name", index: index) else { return XCTFail("approved alias") }
        XCTAssertEqual(name, "Stage Name"); XCTAssertEqual(ids, [1])
        XCTAssertEqual(songs[0].artist, "Stage Name")
    }

    private var compoundLibrary: [SongText] {
        library + [
            SongText(songId: 6, title: "Dramatic Girl (feat. Che Ecru)", artist: "Baby Keem, Che Ecru", album: "Ca$ino", bpm: 80),
            SongText(songId: 7, title: "Dramatic Boy", artist: "Baby Keem", album: "Ca$ino", bpm: 140),
            SongText(songId: 8, title: "Dramatic Girl", artist: "Another Artist", album: "Other", bpm: 75),
            SongText(songId: 9, title: "Who's That Girl", artist: "Baby Keem", album: "Ca$ino", bpm: 90),
            SongText(songId: 10, title: "Called", artist: "Baby Keem", album: "Ca$ino", bpm: 100),
        ]
    }

    func testArtistAndTitleAreExtractedWithStraightCurlyOrMissingPossessiveApostrophes() throws {
        let songs = compoundLibrary
        for query in ["songs similar to baby keems dramatic girl", "songs like Baby Keem's Dramatic Girl",
                      "like Baby Keem’s Dramatic Girl", "like Dramatic Girl by Baby Keem", "like Dramatic Girl Baby Keem",
                      "songs like baby keems dramatic gril"] {
            guard case .named(.title, let name, let ids, let similar) = try discovery(songs).search(query, songs: songs, limit: 15) else {
                return XCTFail("Artist and title must resolve together: \(query)")
            }
            XCTAssertEqual(name, "Dramatic Girl (feat. Che Ecru)", query)
            XCTAssertEqual(ids, [6], "Another artist's exact title must not beat this artist's decorated title")
            XCTAssertFalse(similar.contains { $0.songId == 6 })
        }
    }

    func testQualifiedNamesKeepAliasesAlbumsAndLiteralTitleApostrophes() throws {
        let songs = compoundLibrary
        for (query, expected) in [("like Kanye's Bound", Int64(1)), ("like Baby Keem's Who's That Girl", 9), ("like Baby Keem's song called Called", 10)] {
            guard case .named(.title, _, let ids, _) = try discovery(songs).search(query, songs: songs, limit: 15) else { return XCTFail(query) }
            XCTAssertEqual(ids, [expected], query)
        }
        guard case .named(.album, let name, let ids, _) = try discovery(songs).search("albums like Kanye's Yeezus", songs: songs, limit: 15) else {
            return XCTFail("Artist-qualified album")
        }
        XCTAssertEqual(name, "Yeezus"); XCTAssertEqual(ids, [1, 2])
        guard case .unknownName = VybeQueryRouter.route("like Baby Keem's Snooze", songs: songs) else {
            return XCTFail("Never attribute SZA's song to Baby Keem")
        }
    }

    func testQualifiedAmbiguityAndTempoFiltersKeepTheRightSeed() throws {
        let songs = compoundLibrary
        guard case .ambiguous(_, let choices, _) = try discovery(songs).search("like baby keems dramatic", songs: songs, limit: 15) else {
            return XCTFail("Two Baby Keem titles need a choice")
        }
        XCTAssertEqual(Set(choices.flatMap(\.songIds)), [6, 7])
        guard case .named(.title, _, let ids, let similar) = try discovery(songs).search("like baby keems dramatic under 100 BPM", songs: songs, limit: 15) else {
            return XCTFail("The filter leaves Dramatic Girl as the only matching title")
        }
        XCTAssertEqual(ids, [6]); XCTAssertFalse(similar.contains { [2, 5, 6, 7, 10].contains($0.songId) })
    }

    func testCachedIndexRefreshesAnAliasWithoutEmbeddingSongsAgain() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, track_number, year, date_modified)
            VALUES (1, 'Track', 'Stage Name', 'Album', 1, 1, 1000, '1.mp3', '1.mp3', 1, 2020, 0)
            """)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = NameTestEmbedder()
        let ready = OSAllocatedUnfairLock(initialState: false)
        let engine = VybeEngine(database: database, indexURL: url, makeEmbedder: { model }, publish: { status, _ in
            if case .ready = status { ready.withLock { $0 = true } }
        })
        await engine.refresh()
        for _ in 0..<150 {
            if ready.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready.withLock { $0 })
        let before = model.calls.withLock { $0 }
        try database.db.execute("INSERT INTO artist_alias (alias_key, canonical_key, source, created_at) VALUES ('legal name', 'stage name', 'MANUAL', 0)")
        await engine.refresh()
        guard case .named(.artist, _, let ids, _)? = try await engine.search("Legal Name", limit: 5) else { return XCTFail("updated alias") }
        XCTAssertEqual(ids, [1]); XCTAssertEqual(model.calls.withLock { $0 }, before)
    }
}
