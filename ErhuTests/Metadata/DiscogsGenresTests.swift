import XCTest
@testable import Erhu

final class DiscogsGenresTests: XCTestCase {
    func testCuratedLinksNeverFollowArbitraryHostsOrMalformedIDs() throws {
        XCTAssertEqual(DiscogsReference("https://www.discogs.com/release/249504-Title")?.key, "releases/249504")
        XCTAssertEqual(DiscogsReference("http://www.discogs.com/master/view/42")?.key, "masters/42")
        XCTAssertNil(DiscogsReference("https://discogs.com.evil.test/release/249504"))
        XCTAssertNil(DiscogsReference("https://www.discogs.com/artist/249504"))
        XCTAssertNil(DiscogsReference("https://www.discogs.com/release/0"))
    }

    func testAlbumGenresAreCachedButRecheckedForEveryIdentity() async throws {
        let http = DiscogsHTTP()
        let provider = DiscogsGenres(client: http)
        let ref = try XCTUnwrap(DiscogsReference("https://www.discogs.com/release/42"))
        let first = try await provider.genres(ref, album: "Album", artist: "Artist")
        XCTAssertEqual(first, ["Alternative Rock", "Rock"])
        let wrongArtist = try await provider.genres(ref, album: "Album", artist: "Other Artist")
        XCTAssertTrue(wrongArtist.isEmpty)
        let wrongEdition = try await provider.genres(ref, album: "Album (Deluxe)", artist: "Artist")
        XCTAssertTrue(wrongEdition.isEmpty)
        let calls = await http.calls
        XCTAssertEqual(calls, 1)
    }
}

private actor DiscogsHTTP: HTTPClient {
    private(set) var calls = 0
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        return (Data(#"{"id":42,"title":"Album","artists":[{"name":"Artist (2)"}],"genres":["Rock"],"styles":["Alternative Rock"]}"#.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
