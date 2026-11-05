import XCTest
@testable import Erhu

final class RadioHeroTests: XCTestCase {
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
