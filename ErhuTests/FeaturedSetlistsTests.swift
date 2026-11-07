import XCTest
@testable import Erhu

final class FeaturedSetlistsTests: XCTestCase {
    private var albums: [Album] { (1...6).map {
        Album(id: Int64($0), title: "Album \($0)", artist: "Artist \($0)", artistId: Int64($0), songCount: 1, year: 2026)
    } }
    private func cover(_ id: Int64) -> Song {
        Song(id: id, title: "Song \(id)", artist: "Artist \(id)", album: "Album \(id)", artistId: id, albumId: id,
             durationMs: 180_000, path: "\(id).mp3")
    }
    func testShelfMixesDestinationsWithoutAnAlbumAndItsStationAppearingTwice() {
        let covers = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, cover($0.id)) })
        let selected = FeaturedSetlists.select(albums: albums, covers: covers,
            radioSongs: [cover(1), cover(2), cover(7), cover(7), cover(8)], includesRadio: true)
        XCTAssertEqual(Set(selected.map(\.albumID)).count, selected.count)
        XCTAssertEqual(Set(selected.map(\.id)).count, selected.count)
        XCTAssertTrue(selected.contains { if case .album = $0 { return true }; return false })
        XCTAssertTrue(selected.contains { if case .radio = $0 { return true }; return false })
        XCTAssertEqual(selected.filter { $0.albumID == 7 }.count, 1)
    }
    func testDisablingRadioKeepsEachFeaturedAlbumOnceAndNeedsNoCover() {
        let selected = FeaturedSetlists.select(albums: albums + [albums[0]], covers: [:], radioSongs: [cover(7)], includesRadio: false)
        XCTAssertEqual(selected.map(\.albumID), albums.map(\.id))
        XCTAssertTrue(selected.allSatisfy { if case .album = $0 { return true }; return false })
    }
}
