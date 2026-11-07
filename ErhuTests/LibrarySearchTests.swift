import XCTest
@testable import Erhu

final class LibrarySearchTests: XCTestCase {
    private let artists: [Artist] = [
        Artist(id: 1, name: "Cults", songCount: 1, albumCount: 1),
        Artist(id: 2, name: "The Marías", songCount: 1, albumCount: 1),
        Artist(id: 3, name: "Drake", songCount: 2, albumCount: 1),
        Artist(id: 4, name: "王富贵", songCount: 1, albumCount: 1),
        Artist(id: 5, name: "김지수", songCount: 1, albumCount: 1),
        Artist(id: 6, name: "¥$", songCount: 1, albumCount: 1)
    ]
    private let albums: [Album] = [
        Album(id: 1, title: "Static", artist: "Cults", artistId: 1, songCount: 1, year: 2013),
        Album(id: 2, title: "Submarine", artist: "The Marías", artistId: 2, songCount: 1, year: 2024),
        Album(id: 3, title: "Take Care (Deluxe)", artist: "Drake", artistId: 3, songCount: 2, year: 2011),
        Album(id: 4, title: "生而平凡", artist: "王富贵", artistId: 4, songCount: 1, year: 2025),
        Album(id: 5, title: "The Trunk (Soundtrack)", artist: "김지수", artistId: 5, songCount: 1, year: 2025),
        Album(id: 6, title: "SKY CITY", artist: "¥$", artistId: 6, songCount: 1, year: 2025)
    ]
    private var songs: [Song] {
        [(1, "Always Forever", 1), (2, "No One Noticed", 2), (3, "Headlines", 3), (4, "Over My Dead Body", 3),
         (5, "生而平凡", 4), (6, "Milonga with Lover", 5), (7, "SKY CITY", 6)].map { id, title, albumID in
            let album = albums[albumID - 1]
            return Song(id: Int64(id), title: title, artist: album.artist, album: album.title, artistId: album.artistId,
                        albumId: album.id, durationMs: 180_000, path: "\(id).mp3")
        }
    }
    private func find(_ query: String) -> LibrarySearchResults {
        LibrarySearch.results(query, songs: songs, albums: albums, artists: artists)
    }

    func testReportedAlbumQueriesNeverIncludeUnrelatedNonLatinArtistsOrTracks() {
        for (query, album, song) in [("Static", Int64(1), Int64(1)), ("Submarine", 2, 2), ("sttaic", 1, 1), ("submarien", 2, 2)] {
            let result = find(query)
            XCTAssertTrue(result.artists.isEmpty, query)
            XCTAssertEqual(result.albums.map(\.id), [album], query)
            XCTAssertEqual(result.songs.map(\.id), [song], query)
        }
        XCTAssertEqual(find("Take care").songs.map(\.id), [3, 4])
    }

    func testArtistQueriesExpandOnlyThatArtistsAlbumsAndSongs() {
        for query in ["Drake", "Drkae", "The Marias"] {
            let result = find(query)
            let id: Int64 = query == "The Marias" ? 2 : 3
            XCTAssertEqual(result.artists.map(\.id), [id])
            XCTAssertEqual(result.albums.map(\.id), [id])
            XCTAssertEqual(result.songs.map(\.id), id == 2 ? [2] : [3, 4])
        }
    }

    func testSongQueryShowsItsAlbumWithoutExpandingTheOtherTracks() {
        for query in ["Headlines", "Hedlines", "headlines drkae"] {
            let result = find(query)
            XCTAssertTrue(result.artists.isEmpty)
            XCTAssertEqual(result.albums.map(\.id), [3], query)
            XCTAssertEqual(result.songs.map(\.id), [3], query)
        }
    }

    func testUnicodeAndNumbersArePreservedAndEmptyNamesNeverMatch() {
        XCTAssertEqual(find("王富贵").artists.map(\.id), [4])
        XCTAssertEqual(find("김지수").songs.map(\.id), [6])
        XCTAssertFalse(SearchNormalizer.matches("王富贵", "static"))
        XCTAssertFalse(SearchNormalizer.matches("¥$", "submarine"))
        XCTAssertFalse(SearchNormalizer.matches("", "anything"))
        XCTAssertFalse(SearchNormalizer.matches("2021", "2020"))
        XCTAssertTrue(SearchNormalizer.matches("$ome $exy $ongs 4 U", "some sexy"))
        XCTAssertTrue(find("!!!").songs.isEmpty)
    }
}
