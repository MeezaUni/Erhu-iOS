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

private struct ReferenceTestVectors: SongVectors {
    let vectors: [Int64: [Float]]
    func vectorOf(_ songId: Int64) -> [Float]? { vectors[songId] }
    func rank(limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch] {
        let matches = vectors.compactMap { id, vector in score(id, vector).map { VybeMatch(songId: id, score: $0) } }
        return Array(matches.sorted { $0.score == $1.score ? $0.songId < $1.songId : $0.score > $1.score }.prefix(max(limit, 0)))
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
        for query in ["like bou", "like boudn", "like boudn 2", "like boudn2", "like boudn 2 by Kanye", "like BOUND", "like Bound2", "bound"] {
            guard case .named(.title, let name, let ids, _) = VybeQueryRouter.route(query, songs: library) else { return XCTFail(query) }
            XCTAssertEqual(name, "Bound 2"); XCTAssertEqual(ids, [1])
        }
        for query in ["albums like beautiful fantasy", "albums like fantasy beautiful"] {
            guard case .named(.album, let name, let ids, _) = VybeQueryRouter.route(query, songs: library) else { return XCTFail(query) }
            XCTAssertEqual(name, "My Beautiful Dark Twisted Fantasy"); XCTAssertEqual(ids, [3])
        }
        guard case .unknownName = VybeQueryRouter.route("like bound 3", songs: library) else { return XCTFail("Numbers must stay exact") }
        guard case .unknownName = VybeQueryRouter.route("like bound3", songs: library) else { return XCTFail("Do not remove numeric suffixes as typos") }
        guard case .unknownName = VybeQueryRouter.route("like boudn 3", songs: library) else { return XCTFail("Correcting a title must never change its number") }
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

    func testScreenshotQueryResolvesEachQualifiedSongWithoutEmbeddingTheSentence() throws {
        let songs = compoundLibrary
        for query in ["Like baby keems dramatic girl and bound 2 by Kanye",
                      "songs similar to Baby Keem’s Dramatic Girl and Kanye's Bound 2",
                      "like Bound 2 by Kanye plus Dramatic Girl by Baby Keem",
                      "like baby keems dramatic gril & boudn 2 by Kanye"] {
            guard case .references(let answer) = try discovery(songs).search(query, songs: songs, limit: 30) else { return XCTFail(query) }
            XCTAssertEqual(answer.references.count, 2, query)
            XCTAssertTrue(answer.references.allSatisfy { $0.matches.count == 1 }, query)
            XCTAssertEqual(Set(answer.references.flatMap { $0.matches.flatMap(\.songIds) }), [1, 6], query)
            XCTAssertTrue(answer.wantsSimilar)
            XCTAssertFalse(answer.waitingForIndex)
            XCTAssertFalse(answer.similar.contains { [1, 6].contains($0.songId) })
            XCTAssertFalse(answer.similar.isEmpty)
        }
    }

    func testConjunctionsCommasAndQuotesInsideKnownNamesStayTogether() throws {
        let songs = compoundLibrary + [
            SongText(songId: 11, title: "Love and Hate", artist: "Duo", album: "Duets"),
            SongText(songId: 12, title: "Mrs. Robinson", artist: "Simon & Garfunkel", album: "Bookends"),
            SongText(songId: 13, title: "EARFQUAKE", artist: "Tyler, The Creator", album: "IGOR"),
        ]
        for query in ["like Love and Hate", "like Simon & Garfunkel", "like Tyler, The Creator"] {
            guard case .named = try discovery(songs).search(query, songs: songs, limit: 30) else { return XCTFail(query) }
        }
        for (query, expected) in [("like Love and Hate and Bound 2 by Kanye", Int64(11)),
                                  ("like Simon & Garfunkel and Bound 2", 12),
                                  ("like Tyler, The Creator, Bound 2 by Kanye", 13),
                                  ("like \"Love and Hate\" and \"Bound 2\" by Kanye", 11),
                                  ("like “Love and Hate” and Bound 2", 11)] {
            guard case .references(let answer) = try discovery(songs).search(query, songs: songs, limit: 30) else { return XCTFail(query) }
            XCTAssertEqual(answer.references.count, 2, query)
            XCTAssertEqual(answer.references.first?.matches.first?.songIds, [expected], query)
            XCTAssertEqual(answer.references.last?.matches.first?.songIds, [1], query)
        }
    }

    func testListsAndMissingReferencesKeepEveryClauseVisible() throws {
        let songs = compoundLibrary
        guard case .references(let three) = try discovery(songs).search("like baby keems dramatic girl, bound 2 by Kanye; SZA's Snooze", songs: songs, limit: 30) else {
            return XCTFail("Three references")
        }
        XCTAssertEqual(three.references.map { $0.matches.first?.songIds }, [[6], [1], [4]])
        guard case .references(let partial) = try discovery(songs).search("like Bound 2 and Completely Missing Track", songs: songs, limit: 30) else { return XCTFail("Keep missing clause") }
        XCTAssertEqual(partial.references.map(\.text), ["Bound 2", "Completely Missing Track"])
        XCTAssertEqual(partial.references[0].matches.first?.songIds, [1])
        XCTAssertTrue(partial.references[1].matches.isEmpty)
        XCTAssertFalse(partial.references[1].filteredOut)
        XCTAssertFalse(partial.similar.isEmpty)
        guard case .describe = VybeQueryRouter.route("calm and mellow", songs: songs) else { return XCTFail("Moods remain semantic") }
    }

    func testAmbiguousReferencesAreChosenIndependentlyAndRetainFilters() throws {
        let songs = compoundLibrary + [SongText(songId: 11, title: "Bound for Glory", artist: "Other", album: "Road", bpm: 140)]
        let search = discovery(songs)
        let query = "like baby keems dramatic and bound under 150 BPM"
        guard case .references(let first) = try search.search(query, songs: songs, limit: 30) else { return XCTFail("Multiple ambiguities") }
        XCTAssertEqual(first.references.map { $0.matches.count }, [2, 2])
        XCTAssertTrue(first.similar.isEmpty, "Do not guess while either reference is ambiguous")
        let girl = try XCTUnwrap(first.references[0].matches.first { $0.songIds == [6] })
        let bound = try XCTUnwrap(first.references[1].matches.first { $0.songIds == [1] })
        var selections = [first.references[0].id: girl]
        guard case .references(let second) = try search.search(query, songs: songs, limit: 30, selections: selections) else { return XCTFail("First choice") }
        XCTAssertEqual(second.references[0].matches, [girl])
        XCTAssertEqual(second.references[1].matches.count, 2)
        XCTAssertTrue(second.similar.isEmpty)
        selections[first.references[1].id] = bound
        guard case .references(let final) = try search.search(query, songs: songs, limit: 30, selections: selections) else { return XCTFail("Both choices") }
        XCTAssertEqual(final.references.map { $0.matches.first?.songIds }, [[6], [1]])
        XCTAssertFalse(final.similar.isEmpty)
        XCTAssertFalse(final.similar.contains { [1, 6].contains($0.songId) })
        guard case .references(let invalid) = try search.search(query, songs: songs, limit: 30, selections: [first.references[0].id: bound]) else { return XCTFail("Invalid choice") }
        XCTAssertEqual(invalid.references[0].matches.count, 2, "A choice for another reference must be rejected")

        guard case .references(let filtered) = try search.search("like baby keems dramatic and bound under 100 BPM", songs: songs, limit: 30) else { return XCTFail("Filtered choices") }
        XCTAssertEqual(filtered.references.map { $0.matches.first?.songIds }, [[6], [1]])
        XCTAssertFalse(filtered.similar.contains { [1, 2, 5, 6, 7, 10, 11].contains($0.songId) })
        guard case .references(let excluded) = try search.search("like Dramatic Boy by Baby Keem and Bound 2 under 100 BPM", songs: songs, limit: 30) else { return XCTFail("Filtered seed") }
        XCTAssertTrue(excluded.references[0].filteredOut)
        XCTAssertTrue(excluded.references[0].matches.isEmpty)
        XCTAssertEqual(excluded.references[1].matches.first?.songIds, [1])
    }

    func testBalancedSimilarityUsesBothSeedsAndIgnoresReferenceOrderOrRepetition() throws {
        let songs = compoundLibrary
        let vectors = ReferenceTestVectors(vectors: [1: [10, 0, 0], 6: [0, 1, 0], 2: [1, 0, 0], 3: [1, 1, 0], 4: [0, 1, 0], 5: [0, 0, 1]])
        let search = VybeDiscovery(embedder: NameTestEmbedder(), vectors: vectors)
        var expected: [VybeHit]?
        for query in ["like Bound 2 and baby keems dramatic girl", "like baby keems dramatic girl and Bound 2",
                      "like Bound 2 and baby keems dramatic girl and Bound 2"] {
            guard case .references(let answer) = try search.search(query, songs: songs, limit: 30) else { return XCTFail(query) }
            XCTAssertEqual(answer.similar.first?.songId, 3, "A blend should beat a track matching only one seed, even with unequal vector norms")
            XCTAssertFalse(answer.similar.contains { [1, 6].contains($0.songId) })
            if let expected { XCTAssertEqual(answer.similar, expected) } else { expected = answer.similar }
        }
    }

    func testArtistCatalogDoesNotOutweighOneTrackAndIncompleteSeedsWait() throws {
        let songs = (1...8).map { SongText(songId: Int64($0), title: "Catalog \($0)", artist: "Catalog Artist", album: "Collection") }
            + [SongText(songId: 9, title: "Other Seed", artist: "Other Artist", album: "Other Album"),
               SongText(songId: 10, title: "One Side", artist: "Third", album: "Third Album"),
               SongText(songId: 11, title: "Both Sides", artist: "Fourth", album: "Fourth Album")]
        var vectors = Dictionary(uniqueKeysWithValues: (1...8).map { (Int64($0), [Float(10 * $0), 0, 0]) })
        vectors[9] = [0, 1, 0]; vectors[10] = [1, 0, 0]; vectors[11] = [1, 1, 0]
        let query = "like Catalog Artist and Other Seed"
        let search = VybeDiscovery(embedder: NameTestEmbedder(), vectors: ReferenceTestVectors(vectors: vectors))
        guard case .references(let answer) = try search.search(query, songs: songs, limit: 30) else { return XCTFail("Artist and track") }
        XCTAssertEqual(answer.similar.map(\.songId), [11, 10])
        vectors.removeValue(forKey: 9)
        let partial = VybeDiscovery(embedder: NameTestEmbedder(), vectors: ReferenceTestVectors(vectors: vectors))
        guard case .references(let waiting) = try partial.search(query, songs: songs, limit: 30) else { return XCTFail("Partial index") }
        XCTAssertTrue(waiting.waitingForIndex)
        XCTAssertTrue(waiting.similar.isEmpty, "Do not silently rank only from the large artist catalog")
        XCTAssertEqual(waiting.references.count, 2)
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
