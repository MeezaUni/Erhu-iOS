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

    func testAwayAddressMustBeHttpsAndClientsSwitchAddress() throws {
        XCTAssertEqual("https://pc.tail1234.ts.net", ServerAccount.normalizedRemoteURL(from: " pc.tail1234.ts.net/ ")?.absoluteString)
        XCTAssertEqual("https://music.example.com/navidrome", ServerAccount.normalizedRemoteURL(from: "https://music.example.com/navidrome/app")?.absoluteString)
        XCTAssertNil(ServerAccount.normalizedRemoteURL(from: "http://pc.tail1234.ts.net"))
        XCTAssertNil(ServerAccount.normalizedRemoteURL(from: ""))
        var account = ServerAccount(id: UUID(), name: "Home", baseURL: URL(string: "http://192.168.1.20:4533")!, username: "listener")
        account.remoteURL = URL(string: "https://pc.tail1234.ts.net")
        let home = SubsonicClient(account: account, password: "pw")
        let away = SubsonicClient(account: account, password: "pw", away: true)
        XCTAssertTrue(home.url("ping").absoluteString.hasPrefix("http://192.168.1.20:4533/rest/ping?"))
        XCTAssertTrue(away.url("ping").absoluteString.hasPrefix("https://pc.tail1234.ts.net/rest/ping?"))
        // An account saved before away addresses existed still loads.
        let old = #"{"id":"00000000-0000-0000-0000-000000000002","name":"Old","baseURL":"http://10.0.0.2:4533","username":"u"}"#
        let decoded = try JSONDecoder().decode(ServerAccount.self, from: Data(old.utf8))
        XCTAssertNil(decoded.remoteURL)
        XCTAssertEqual(decoded.baseURL, SubsonicClient(account: decoded, password: "", away: true).base, "no away address: home is used")
    }

    // MARK: Pairing links, favourites and recents

    func testPairingLinkFillsInTheServerButNeverAPassword() throws {
        let url = try XCTUnwrap(URL(string: "erhu://server?url=http%3A%2F%2F192.168.1.20%3A4533%2F&user=listener&name=Living%20room%20PC&password=nope"))
        let invite = try XCTUnwrap(ServerInvite(url: url))
        XCTAssertEqual("http://192.168.1.20:4533", invite.address)
        XCTAssertEqual("listener", invite.username)
        XCTAssertEqual("Living room PC", invite.name)
        XCTAssertEqual("", invite.remote)
        let away = try XCTUnwrap(ServerInvite(url: URL(string: "erhu://server?url=http%3A%2F%2F192.168.1.20%3A4533&remote=https%3A%2F%2Fpc.tail1234.ts.net%2F")!))
        XCTAssertEqual("https://pc.tail1234.ts.net", away.remote)
        let plain = try XCTUnwrap(ServerInvite(url: URL(string: "erhu://server?url=http%3A%2F%2F192.168.1.20%3A4533&remote=http%3A%2F%2Fpc.example.com")!))
        XCTAssertEqual("", plain.remote, "an away address must be HTTPS")
        XCTAssertNil(ServerInvite(url: URL(string: "erhu://server?user=a")!), "no address")
        XCTAssertNil(ServerInvite(url: URL(string: "erhu://other?url=http://x")!))
        XCTAssertNil(ServerInvite(url: URL(string: "https://server?url=http://x")!))
    }

    func testFavouritesDecodeAndSongsRoundTripForRecents() throws {
        let json = #"{"subsonic-response":{"status":"ok","starred2":{"song":[{"id":"s1","title":"Loved","artist":"A","duration":200,"suffix":"flac","starred":"2026-11-15T11:02:05Z"}]}}}"#
        let song = try XCTUnwrap(try decode(json).starred2?.song.first)
        XCTAssertNotNil(song.starred)
        let item = StreamedSong(accountId: account.id, song: song, playedAt: Date(timeIntervalSince1970: 1), server: "http://192.168.1.20:4533", username: "listener")
        let restored = try JSONDecoder().decode([StreamedSong].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual([item], restored)
        XCTAssertEqual("flac", restored[0].song.fileExtension)
    }

    func testRecentlyStreamedIsNewestFirstWithoutRepeatsAndCapped() throws {
        func item(_ id: Int, _ at: TimeInterval = 0) throws -> StreamedSong {
            let json = #"{"subsonic-response":{"status":"ok","album":{"id":"a","name":"x","song":[{"id":"\#(id)","title":"T\#(id)"}]}}}"#
            return StreamedSong(accountId: account.id, song: try XCTUnwrap(try decode(json).album).song[0], playedAt: Date(timeIntervalSince1970: at))
        }
        var recent: [StreamedSong] = []
        for id in [1, 2, 3] { recent = ServerStore.addingRecent(try item(id), to: recent) }
        recent = ServerStore.addingRecent(try item(1, 9), to: recent)
        XCTAssertEqual(["1", "3", "2"], recent.map(\.song.id))
        for id in 10..<(10 + ServerStore.recentLimit) { recent = ServerStore.addingRecent(try item(id), to: recent) }
        XCTAssertEqual(ServerStore.recentLimit, recent.count)
        XCTAssertFalse(recent.contains { $0.song.id == "1" }, "the oldest entries fall off")
    }

    // MARK: Streaming and downloads

    func testRecentlyStreamedAlbumsKeepTheLastFiveAndDropTheOldest() throws {
        func album(_ song: Int, album: Int?, server: String = "http://192.168.1.20:4533") throws -> StreamedAlbum? {
            let albumField = album.map { ",\"albumId\":\"al-\($0)\",\"album\":\"Album \($0)\",\"coverArt\":\"al-\($0)_c\"" } ?? ""
            let data = Data("{\"id\":\"s\(song)\",\"title\":\"Song \(song)\"\(albumField)}".utf8)
            let song = try JSONDecoder().decode(ServerSong.self, from: data)
            return StreamedAlbum(StreamedSong(accountId: UUID(), song: song, playedAt: Date(), server: server, username: "listener"))
        }
        XCTAssertNil(try album(9, album: nil), "a song with no album adds nothing")
        var list: [StreamedAlbum] = []
        var dropped: [StreamedAlbum] = []
        for (song, number) in [(1, 1), (2, 2), (3, 1), (4, 3), (5, 4), (6, 5)] {
            (list, dropped) = ServerStore.addingAlbum(try XCTUnwrap(try album(song, album: number)), to: list)
            XCTAssertTrue(dropped.isEmpty)
        }
        XCTAssertEqual(["al-5", "al-4", "al-3", "al-1", "al-2"], list.map(\.albumId), "newest first, once per album")
        // A sixth album pushes the oldest off; its cover is what gets deleted.
        (list, dropped) = ServerStore.addingAlbum(try XCTUnwrap(try album(7, album: 6)), to: list)
        XCTAssertEqual(5, list.count)
        XCTAssertEqual(["al-2"], dropped.map(\.albumId))
        XCTAssertEqual("Album 6", list[0].title)
        // The same album streamed again after the server was added again (new account ID) is one entry.
        let again = try XCTUnwrap(try album(8, album: 6))
        XCTAssertEqual(again.id, list[0].id)
        XCTAssertEqual(again.coverFile, list[0].coverFile)
        XCTAssertTrue(again.coverFile.path.hasPrefix(LibraryPaths.supportFolder.path), "covers aren't in Caches, which iOS may clear")
        XCTAssertEqual(list, try JSONDecoder().decode([StreamedAlbum].self, from: JSONEncoder().encode(list)))
    }

    func testRecentSearchesKeepServerItemsAndLibraryIdsBetweenLaunches() throws {
        let album = RecentServerItem(accountId: UUID(), id: "al-1", title: "Live", subtitle: "Band", coverArt: "al-1_x",
                                     server: "http://192.168.1.20:4533", username: "listener")
        var list: [SavedRecentSearch] = []
        for item in [SavedRecentSearch.song(3), .serverAlbum(album), .album(9), .song(3)] {
            list = SavedRecentSearch.adding(item, to: list, limit: 3)
        }
        XCTAssertEqual([.song(3), .album(9), .serverAlbum(album)], list, "newest first, once each")
        // The same server album saved under a re-added account is the same recent item.
        let again = RecentServerItem(accountId: UUID(), id: album.id, title: album.title, subtitle: album.subtitle,
                                     coverArt: album.coverArt, server: album.server, username: album.username)
        XCTAssertEqual(SavedRecentSearch.serverAlbum(album).key, SavedRecentSearch.serverAlbum(again).key)
        XCTAssertEqual(list, try JSONDecoder().decode([SavedRecentSearch].self, from: JSONEncoder().encode(list)))
        XCTAssertEqual(2, SavedRecentSearch.adding(.artist(1), to: list, limit: 2).count)
    }

    func testServerPlaybackSourceSurvivesSaving() throws {
        let source = PlaybackSource.server(account: UUID(), album: "al-1", title: "Live")
        XCTAssertEqual(source, try JSONDecoder().decode(PlaybackSource.self, from: JSONEncoder().encode(source)))
    }

    @MainActor
    func testStreamedSongsInTheQueueComeBackAfterARestart() throws {
        let album = try XCTUnwrap(try decode(SubsonicFixtures.album).album)
        let streamed = album.song.prefix(2).map { ServerStream.shared.song(for: $0, account: account, quality: .mp3_192) }
        let snapshot = streamed.compactMap { ServerStream.shared.persisted($0) }
        XCTAssertEqual(2, snapshot.count)
        let saved = PersistedPlaybackState(queueSongIds: [7, streamed[0].id, streamed[1].id], currentIndex: 1, positionMs: 4_000,
                                           streamSongs: snapshot)
        // Written to disk and read back by the next launch.
        let reloaded = try JSONDecoder().decode(PersistedPlaybackState.self, from: JSONEncoder().encode(saved))
        let rebuilt = (reloaded.streamSongs ?? []).map { ServerStream.shared.restore($0) }
        XCTAssertEqual(streamed.map(\.id), rebuilt.map(\.id))
        XCTAssertEqual(streamed.map(\.path), rebuilt.map(\.path), "same quality, same cached file")
        // Song 7 left the library meanwhile: the streamed songs and the position survive.
        let queue = try XCTUnwrap(buildRestoredQueue(reloaded, available: rebuilt))
        XCTAssertEqual(streamed.map(\.id), queue.songs.map(\.id))
        XCTAssertEqual(0, queue.startIndex)
        XCTAssertEqual(4_000, queue.startPositionMs)
        // A snapshot from before this change still loads.
        let old = #"{"queueSongIds":[1],"currentIndex":0,"positionMs":0,"shuffleModeEnabled":false,"repeatMode":"OFF","queueCollectionKeys":[""]}"#
        XCTAssertNil(try JSONDecoder().decode(PersistedPlaybackState.self, from: Data(old.utf8)).streamSongs)
    }

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
