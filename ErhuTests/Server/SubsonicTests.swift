import XCTest
@testable import Erhu

final class SubsonicTests: XCTestCase {
    private func decode(_ json: String) throws -> SubsonicResponse {
        try SubsonicClient.decode(Data(json.utf8), response: nil)
    }

    private let account = ServerAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Home",
                                        baseURL: URL(string: "http://192.168.1.20:4533")!, username: "listener")

    // MARK: Authentication and URLs

    func testTokenMatchesTheSubsonicSpecificationExample() {
        // From the Subsonic API documentation: password "sesame", salt "c19b2d".
        XCTAssertEqual("26719a1196d2a940705a59634eb18eab", SubsonicClient.token(password: "sesame", salt: "c19b2d"))
    }

    func testRequestURLCarriesTokenNotPassword() throws {
        let client = SubsonicClient(account: account, password: "sesame")
        let url = client.url("getAlbum", [URLQueryItem(name: "id", value: "a 1")], salt: "c19b2d")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual("/rest/getAlbum", components.path)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual("listener", items["u"])
        XCTAssertEqual("26719a1196d2a940705a59634eb18eab", items["t"])
        XCTAssertEqual("c19b2d", items["s"])
        XCTAssertEqual(SubsonicClient.apiVersion, items["v"])
        XCTAssertEqual("Erhu", items["c"])
        XCTAssertEqual("json", items["f"])
        XCTAssertEqual("a 1", items["id"])
        XCTAssertFalse(url.absoluteString.contains("sesame"))
    }

    func testSaltsAreFreshPerRequestButStableForMedia() {
        let client = SubsonicClient(account: account, password: "pw")
        XCTAssertNotEqual(client.url("ping"), client.url("ping"))
        XCTAssertEqual(client.coverArtURL("al-1"), client.coverArtURL("al-1"))
    }

    func testStreamURLAsksForTheOriginalOrAConvertedCopy() throws {
        let client = SubsonicClient(account: account, password: "pw")
        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let original = items(client.streamURL("s1", quality: .original))
        XCTAssertEqual("raw", original["format"])
        XCTAssertNil(original["maxBitRate"])
        XCTAssertNil(original["f"], "media requests must not ask for JSON")
        let small = items(client.streamURL("s1", quality: .mp3_128))
        XCTAssertEqual("mp3", small["format"])
        XCTAssertEqual("128", small["maxBitRate"])
        XCTAssertTrue(client.downloadURL("s1").path.hasSuffix("/rest/download"))
    }

    func testServerAddressesAreNormalized() {
        func normal(_ text: String) -> String? { ServerAccount.normalizedURL(from: text)?.absoluteString }
        XCTAssertEqual("http://192.168.1.20:4533", normal("192.168.1.20:4533"))
        XCTAssertEqual("http://192.168.1.20:4533", normal(" http://192.168.1.20:4533/ "))
        XCTAssertEqual("http://nas.local:4533", normal("http://nas.local:4533/app/"))
        XCTAssertEqual("https://music.example.com/navidrome", normal("HTTPS://music.example.com/navidrome/rest"))
        XCTAssertEqual("https://music.example.com", normal("https://music.example.com/#/album"))
        XCTAssertNil(normal(""))
        XCTAssertNil(normal("not a server"))
        XCTAssertNil(normal("ftp://192.168.1.20"))
    }

    func testBasePathIsKeptInRequests() throws {
        var proxied = account
        proxied.baseURL = URL(string: "https://music.example.com/navidrome")!
        let url = SubsonicClient(account: proxied, password: "pw").url("ping")
        XCTAssertEqual("/navidrome/rest/ping", URLComponents(url: url, resolvingAgainstBaseURL: false)?.path)
    }

    // MARK: Responses recorded from Navidrome

    func testDecodesAnAlbumWithSongs() throws {
        let album = try XCTUnwrap(try decode(SubsonicFixtures.album).album)
        XCTAssertEqual("8-bit lagerfeuer", album.name)
        XCTAssertEqual("pornophonique", album.artist)
        XCTAssertEqual(8, album.songCount)
        XCTAssertEqual(2007, album.year)
        XCTAssertEqual(["sad robot", "take me to the bonus level because i need an extra life"], album.song.map(\.title))
        let first = try XCTUnwrap(album.song.first)
        XCTAssertEqual(1, first.track)
        XCTAssertEqual(312, first.duration)
        XCTAssertEqual("mp3", first.fileExtension)
        XCTAssertEqual(album.id, first.albumId)
        XCTAssertNotNil(first.coverArt)
    }

    func testDecodesAlbumListsArtistsSearchAndPlaylists() throws {
        XCTAssertEqual(["8-bit lagerfeuer", "Between two worlds", "Big House"], try decode(SubsonicFixtures.albumList2).albumList2?.album.map(\.name))
        let index = try XCTUnwrap(try decode(SubsonicFixtures.artists).artists)
        XCTAssertEqual(["#", "B"], index.index.map(\.name))
        XCTAssertEqual(["2 Mello", "Back On Earth", "Binaerpilot"], index.allArtists.map(\.name))
        let search = try XCTUnwrap(try decode(SubsonicFixtures.search3).searchResult3)
        XCTAssertEqual(2, search.song.count)
        XCTAssertEqual(1, search.album.count)
        XCTAssertTrue(search.artist.isEmpty, "a missing list decodes as empty")
        XCTAssertEqual([12, 2], try decode(SubsonicFixtures.playlists).playlists?.playlist.map { $0.songCount ?? 0 })
    }

    func testWrongPasswordBecomesAReadableError() {
        XCTAssertThrowsError(try decode(SubsonicFixtures.error)) { error in
            XCTAssertEqual(SubsonicError.server(code: 40, message: "Wrong username or password"), error as? SubsonicError)
            XCTAssertEqual(String(localized: "Wrong username or password."), error.localizedDescription)
        }
    }

    func testNonMusicServerResponsesAreRejected() {
        XCTAssertThrowsError(try decode("<html>router login</html>")) { XCTAssertEqual(.unreadableResponse, $0 as? SubsonicError) }
        let notFound = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 404, httpVersion: nil, headerFields: nil)
        XCTAssertThrowsError(try SubsonicClient.decode(Data(), response: notFound)) { XCTAssertEqual(.http(404), $0 as? SubsonicError) }
    }

    func testOlderServersMaySendSingleItemsAndNumericIds() throws {
        let json = #"{"subsonic-response":{"status":"ok","version":"1.13.0","album":{"id":42,"title":"Solo","song":{"id":7,"title":"Only one","duration":61}}}}"#
        let album = try XCTUnwrap(try decode(json).album)
        XCTAssertEqual("42", album.id)
        XCTAssertEqual("Solo", album.name)
        XCTAssertEqual(["7"], album.song.map(\.id))
        XCTAssertEqual("mp3", album.song[0].fileExtension, "no suffix falls back to mp3")
    }

    // MARK: Streaming and downloads

    @MainActor
    func testStreamedSongsLiveInTheCacheWithStableNegativeIds() throws {
        let album = try XCTUnwrap(try decode(SubsonicFixtures.album).album)
        let remote = album.song[0]
        let song = ServerStream.shared.song(for: remote, account: account, quality: .original)
        XCTAssertTrue(song.isStream)
        XCTAssertLessThan(song.id, 0)
        XCTAssertEqual(song.id, ServerStream.shared.song(for: remote, account: account, quality: .mp3_128).id, "one ID per server song")
        XCTAssertEqual(312_000, song.durationMs)
        XCTAssertEqual("sad robot", song.title)
        XCTAssertTrue(song.url.path.hasPrefix(ServerStreamPaths.cacheFolder.path))
        XCTAssertTrue(song.url.lastPathComponent.hasSuffix(".original.mp3"))
        let small = ServerStream.shared.song(for: remote, account: account, quality: .mp3_192)
        XCTAssertNotEqual(song.url, small.url, "another quality is a separate cached file")
        XCTAssertTrue(small.url.lastPathComponent.hasSuffix(".mp3_192.mp3"))
        XCTAssertNil(LibraryPaths.relativePath(of: song.url), "streams never sit in the Erhu folder")
        // A library song is unaffected.
        let local = Song(id: 1, title: "A", artist: "B", album: "C", durationMs: 1, path: "B/C/a.mp3")
        XCTAssertFalse(local.isStream)
        XCTAssertEqual(LibraryPaths.musicFolder.appendingPathComponent("B/C/a.mp3"), local.url)
    }

    func testDownloadedSongsGetSafeLibraryPaths() throws {
        let json = #"{"subsonic-response":{"status":"ok","album":{"id":"1","name":"x","song":[{"id":"9","title":"What? / Why: \"Now\"","artist":"AC/DC","album":"..Live","track":3,"discNumber":2,"suffix":"FLAC"},{"id":"10","title":""}]}}}"#
        let songs = try XCTUnwrap(try decode(json).album).song
        XCTAssertEqual("From Server/AC DC/Live/2-03 What    Why   Now.flac", ServerStore.downloadPath(for: songs[0]))
        XCTAssertEqual("From Server/Unknown Artist/Unknown Album/Track.mp3", ServerStore.downloadPath(for: songs[1]))
    }
}
