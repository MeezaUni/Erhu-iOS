import XCTest
@testable import Erhu

final class RadioHeroTests: XCTestCase {
    func testStationPalettePrefersItsLeadArtistPhotoAndIgnoresUnrelatedSongs() {
        let seed = Song(id: 1, title: "Seed", artist: "Lead", album: "Album", artistId: 10, durationMs: 1000, path: "seed.mp3")
        let unrelated = Song(id: 2, title: "Playing elsewhere", artist: "Other", album: "Other", artistId: 20, durationMs: 1000, path: "other.mp3")
        let lead = Artist(id: 10, name: "Lead", songCount: 1, albumCount: 1, artworkPath: "/tmp/lead.png")
        let other = Artist(id: 20, name: "Other", songCount: 1, albumCount: 1, artworkPath: "/tmp/other.png")
        let plan = RadioPlan(seed: .song(1), name: "Seed", startSongId: 1, songIds: [], basedOn: [])
        XCTAssertEqual(RadioHeroSelection.paletteSource(plan: plan, library: [unrelated, seed], artists: [other, lead]),
                       .image(URL(fileURLWithPath: "/tmp/lead.png")))
        XCTAssertEqual(RadioHeroSelection.paletteSource(plan: plan, library: [seed], artists: []), .track(seed.url))
        XCTAssertEqual(RadioHeroSelection.paletteSource(plan: nil, library: [unrelated, seed], artists: [other, lead]), .track(nil))
    }

    func testCollageUsesSeedFirstAndTwoDistinctArtistsActuallyInStation() {
        func song(_ id: Int64, _ artist: Int64) -> Song {
            Song(id: id, title: "Track", artist: "Artist \(artist)", album: "Album", artistId: artist, durationMs: 1000, path: "\(id).mp3")
        }
        let songs = [song(1, 10), song(2, 10), song(3, 20), song(4, 30), song(5, 40)]
        let plan = RadioPlan(seed: .song(1), name: "Track", startSongId: 1, songIds: [2, 3, 4], basedOn: [])
        XCTAssertEqual(RadioHeroSelection.songs(plan: plan, library: songs).map(\.id), [1, 3, 4])
        let singleArtist = RadioPlan(seed: .song(1), name: "Track", startSongId: 1, songIds: [2], basedOn: [])
        XCTAssertEqual(RadioHeroSelection.songs(plan: singleArtist, library: songs).map(\.id), [1])
    }
}
