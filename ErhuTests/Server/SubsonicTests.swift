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

    func testServerAlbumsJoinTheLibrarysInItsOrder() {
        let account = UUID()
        let local = [Album(id: 1, title: "Apple", artist: "B", artistId: 0, songCount: 1, year: 2001),
                     Album(id: 2, title: "Cherry", artist: "A", artistId: 0, songCount: 1, year: 1999)]
        let server = [ServerCatalog.Album(id: "x", name: "Banana", artist: "C", coverArt: nil, year: 2010),
                      ServerCatalog.Album(id: "y", name: "Date", artist: "A", coverArt: nil, year: nil)]
        let byTitle = ServerLibraryMerge.albums(local: local, server: server, accountId: account, sort: .title, searching: false)
        XCTAssertEqual(["Apple", "Banana", "Cherry", "Date"], byTitle.map(\.title))
        let newest = ServerLibraryMerge.albums(local: local.sorted { $0.year > $1.year }, server: server, accountId: account, sort: .newestYear, searching: false)
        XCTAssertEqual(["Banana", "Apple", "Cherry", "Date"], newest.map(\.title))
        // Sorts only the library knows (most played) and searches: the server's follow.
        XCTAssertEqual(["Apple", "Cherry", "Banana", "Date"],
                       ServerLibraryMerge.albums(local: local, server: server, accountId: account, sort: .mostPlayed, searching: false).map(\.title))
        XCTAssertEqual(2, ServerLibraryMerge.albums(local: local, server: server, accountId: nil, sort: .title, searching: false).count,
                       "no server connected: only the library")
        if case .server(let id, _) = byTitle[1] { XCTAssertEqual(account, id) } else { XCTFail("Banana is the server's") }
    }

    func testServerMusicJoinsTheLibrarysOwnAlbumsWithoutDuplicates() throws {
        func remote(_ id: String, _ title: String, track: Int, album: String = "Parachutes", albumId: String = "p") throws -> ServerSong {
            let json = #"{"id":"\#(id)","title":"\#(title)","artist":"Coldplay","album":"\#(album)","albumId":"\#(albumId)","track":\#(track)}"#
            return try JSONDecoder().decode(ServerSong.self, from: Data(json.utf8))
        }
        let account = UUID()
        let parachutes = Album(id: 1, title: "Parachutes", artist: "Coldplay", artistId: 0, songCount: 2, year: 2000)
        var catalog = ServerCatalog()
        catalog.albums = [.init(id: "p", name: "parachutes", artist: "Coldplay, Guest", coverArt: nil, year: 2000),
                          .init(id: "x", name: "X&Y", artist: "Coldplay", coverArt: nil, year: 2005)]
        catalog.songs = [try remote("1", "Don't Panic", track: 1), try remote("2", "Shiver", track: 2),
                         try remote("3", "Yellow", track: 5), try remote("4", "Fix You", track: 4, album: "X&Y", albumId: "x")]
        let index = ServerCatalogIndex(catalog)

        // An album the library has shows once, as the library's; one only on the server joins.
        let grid = ServerLibraryMerge.albums(local: [parachutes], server: catalog.albums, accountId: account, sort: .title, searching: false)
        XCTAssertEqual(["Parachutes", "X&Y"], grid.map(\.title))
        if case .local = grid[0] {} else { XCTFail("Parachutes is the library's") }
        XCTAssertEqual(["Parachutes"], ServerLibraryMerge.albums(local: [parachutes], server: catalog.albums, accountId: account,
                                                                 sort: .title, searching: false, source: .local).map(\.title))
        XCTAssertEqual(["X&Y"], ServerLibraryMerge.albums(local: [parachutes], server: catalog.albums, accountId: account,
                                                          sort: .title, searching: false, source: .streamed).map(\.title))

        // The library's album gains the server's songs it lacks, in track order.
        let local = [Song(id: 1, title: "Dont Panic", artist: "Coldplay", album: "Parachutes", durationMs: 1, path: "a.mp3", trackNumber: 1),
                     Song(id: 2, title: "Shiver", artist: "Coldplay", album: "Parachutes", durationMs: 1, path: "b.mp3", trackNumber: 2)]
        let extras = ServerLibraryMerge.extraSongs(for: parachutes, localSongs: local, in: index)
        XCTAssertEqual(["Yellow"], extras.map(\.title))
        let yellow = Song(id: -3, title: "Yellow", artist: "Coldplay", album: "Parachutes", durationMs: 1, path: "erhu-stream:y", trackNumber: 5)
        let unnumbered = Song(id: 3, title: "Bonus", artist: "Coldplay", album: "Parachutes", durationMs: 1, path: "c.mp3")
        XCTAssertEqual(["Dont Panic", "Shiver", "Yellow", "Bonus"],
                       ServerLibraryMerge.albumTracks([local[0], unnumbered, local[1]], [yellow]).map(\.title))

        // Songs: one list without the library's songs twice, and the Source filter.
        let songs = ServerLibraryMerge.songs(in: index, query: "", genre: "", excluding: .init(local))
        XCTAssertEqual(["Fix You", "Yellow"], songs.map(\.title))
        let fixYou = Song(id: -4, title: "Fix You", artist: "Coldplay", album: "X&Y", durationMs: 1, path: "erhu-stream:f")
        XCTAssertEqual(["Dont Panic", "Fix You", "Shiver", "Yellow"],
                       ServerLibraryMerge.songList(local: local, streamed: [fixYou, yellow], sort: .title, searching: false, source: .all).map(\.title))
        XCTAssertEqual(["Dont Panic", "Shiver"],
                       ServerLibraryMerge.songList(local: local, streamed: [fixYou, yellow], sort: .title, searching: false, source: .local).map(\.title))
        XCTAssertEqual(["Fix You", "Yellow"],
                       ServerLibraryMerge.songList(local: local, streamed: [fixYou, yellow], sort: .title, searching: false, source: .streamed).map(\.title))
    }

    func testArtistCreditsOpenEachArtistAndServerArtistsMergeByName() throws {
        func names(_ credit: String, local: Set<String> = [], server: Set<String> = []) -> [String] {
            ServerLibraryMerge.artistNames(credit, local: Set(local.map(ServerLibraryMerge.artistKey)),
                                           server: Set(server.map(ServerLibraryMerge.artistKey)))
        }
        XCTAssertEqual(["Alicia Keys", "Kendrick Lamar"], names("Alicia Keys, Kendrick Lamar", local: ["Kendrick Lamar"]))
        XCTAssertEqual(["Drake", "Future"], names("Drake feat. Future"))
        // One artist whose name has a separator stays whole, from the library or the server.
        XCTAssertEqual(["Simon & Garfunkel"], names("Simon & Garfunkel", local: ["Simon & Garfunkel"]))
        XCTAssertEqual(["Simon & Garfunkel", "Paul Simon"], names("Simon & Garfunkel, Paul Simon", server: ["Simon & Garfunkel"]))
        // ...but not a server's comma list of artists.
        XCTAssertEqual(["Alicia Keys", "Kendrick Lamar"],
                       names("Alicia Keys, Kendrick Lamar", local: ["Kendrick Lamar"], server: ["Alicia Keys, Kendrick Lamar"]))

        func remote(_ id: String, _ title: String, artist: String, album: String, albumId: String) throws -> ServerSong {
            let json = #"{"id":"\#(id)","title":"\#(title)","artist":"\#(artist)","album":"\#(album)","albumId":"\#(albumId)","coverArt":"c-\#(albumId)"}"#
            return try JSONDecoder().decode(ServerSong.self, from: Data(json.utf8))
        }
        var catalog = ServerCatalog()
        catalog.artists = [.init(id: "a1", name: "Alicia Keys, Kendrick Lamar", coverArt: nil, albumCount: 1)]
        catalog.albums = [.init(id: "al1", name: "It's On Again", artist: "Alicia Keys, Kendrick Lamar", coverArt: "c-al1", year: 2014)]
        catalog.songs = [try remote("s1", "It's On Again", artist: "Alicia Keys, Kendrick Lamar", album: "It's On Again", albumId: "al1"),
                         try remote("s2", "Fallin'", artist: "Alicia Keys", album: "Songs in A Minor", albumId: "al2")]
        let artists = ServerLibraryMerge.namedArtists(in: ServerCatalogIndex(catalog), local: [ServerLibraryMerge.artistKey("Kendrick Lamar")])
        let alicia = try XCTUnwrap(artists[ServerLibraryMerge.artistKey("Alicia Keys")])
        XCTAssertEqual(["s1", "s2"], alicia.songIds)
        XCTAssertEqual(["al1"], alicia.albumIds)
        XCTAssertEqual("c-al1", alicia.coverArt)
        XCTAssertEqual(["s1"], artists[ServerLibraryMerge.artistKey("Kendrick Lamar")]?.songIds)
        XCTAssertNil(artists[ServerLibraryMerge.artistKey("Alicia Keys, Kendrick Lamar")], "a credit of two is not an artist")
        // The same song credited two ways is still one song.
        XCTAssertTrue(ServerLibraryMerge.sameArtist("Alicia Keys feat. Kendrick Lamar", "Alicia Keys, Kendrick Lamar"))
        XCTAssertFalse(ServerLibraryMerge.sameArtist("Alicia Keys", "Kendrick Lamar"))
        let local = Song(id: 9, title: "It's On Again", artist: "Alicia Keys feat. Kendrick Lamar", album: "x", durationMs: 1, path: "x.mp3")
        XCTAssertTrue(ServerLibraryMerge.SongKeys([local]).contains(title: "It’s On Again", artist: "Alicia Keys, Kendrick Lamar"))
    }

    func testServerCopiesOfASongShowOnce() throws {
        func remote(_ id: String, _ title: String, duration: Int, album: String = "Depression Cherry") throws -> ServerSong {
            let json = #"{"id":"\#(id)","title":"\#(title)","artist":"Beach House","album":"\#(album)","duration":\#(duration)}"#
            return try JSONDecoder().decode(ServerSong.self, from: Data(json.utf8))
        }
        let songs = [try remote("1", "Space Song", duration: 320), try remote("2", "Space Song", duration: 321),
                     try remote("3", "Space Song", duration: 200), try remote("4", "Space Song", duration: 320, album: "Live"),
                     try remote("5", "Myth", duration: 258)]
        // Same title, artist, album and length: one. Another length or album is another song.
        XCTAssertEqual(["1", "3", "4", "5"], ServerCatalog.uniqueSongs(songs).map(\.id))
        var catalog = ServerCatalog()
        catalog.songs = songs
        XCTAssertEqual(4, ServerCatalogIndex(catalog).catalog.songs.count)
    }

    func testSmallLossySongsStreamUnchangedAndConvertedStreamsCanStartPartway() throws {
        func remote(_ suffix: String, _ rate: Int) throws -> ServerSong {
            try JSONDecoder().decode(ServerSong.self, from: Data(#"{"id":"x","title":"t","suffix":"\#(suffix)","bitRate":\#(rate)}"#.utf8))
        }
        XCTAssertEqual(.original, StreamQuality.mp3_192.applied(to: try remote("mp3", 320)))
        XCTAssertEqual(.original, StreamQuality.mp3_128.applied(to: try remote("m4a", 256)))
        XCTAssertEqual(.mp3_192, StreamQuality.mp3_192.applied(to: try remote("flac", 1000)))
        XCTAssertEqual(.mp3_192, StreamQuality.mp3_192.applied(to: try remote("m4a", 900)), "ALAC is converted")
        XCTAssertEqual(.original, StreamQuality.original.applied(to: try remote("flac", 1000)))
        let client = SubsonicClient(account: account, password: "p")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: client.streamURL("s1", quality: .mp3_192, offsetSeconds: 95), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual("95", items["timeOffset"])
        XCTAssertEqual("true", items["estimateContentLength"])
    }

    func testStreamMediaReadsTheFilesLengthFromARangeReply() throws {
        let url = URL(string: "https://pc.example/rest/stream")!
        let partial = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                                    headerFields: ["Content-Range": "bytes 0-131071/5123456", "Content-Length": "131072"]))
        XCTAssertEqual(5_123_456, StreamMedia.totalLength(partial, offset: 0))
        // A server ignoring the range sends it all: its length is the file's.
        let whole = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4000"]))
        XCTAssertEqual(4_000, StreamMedia.totalLength(whole, offset: 0))
        XCTAssertNil(StreamMedia.totalLength(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [:])), offset: 0))
    }

    func testServerCatalogSearchMatchesLikeTheLibraryAndSurvivesSaving() throws {
        func song(_ id: String, _ title: String, artist: String, album: String, albumId: String, artistId: String) throws -> ServerSong {
            let json = #"{"id":"\#(id)","title":"\#(title)","artist":"\#(artist)","album":"\#(album)","albumId":"\#(albumId)","artistId":"\#(artistId)","track":1}"#
            return try JSONDecoder().decode(ServerSong.self, from: Data(json.utf8))
        }
        var catalog = ServerCatalog()
        catalog.artists = [.init(id: "ar1", name: "Vancouver Sleep Clinic", coverArt: nil, albumCount: 1),
                           .init(id: "ar2", name: "The 1975", coverArt: nil, albumCount: 1)]
        catalog.albums = [.init(id: "al1", name: "Somebody Else", artist: "Vancouver Sleep Clinic", coverArt: "al1", year: 2022),
                          .init(id: "al2", name: "I like it when you sleep", artist: "The 1975", coverArt: "al2", year: 2016)]
        catalog.songs = [try song("s1", "Somebody Else", artist: "Vancouver Sleep Clinic", album: "Somebody Else", albumId: "al1", artistId: "ar1"),
                         try song("s2", "Somebody Else", artist: "The 1975", album: "I like it when you sleep", albumId: "al2", artistId: "ar2"),
                         try song("s3", "Addicted to You", artist: "Avicii", album: "True", albumId: "al3", artistId: "ar3")]
        let index = ServerCatalogIndex(catalog)
        // A few letters are enough, as in the library.
        XCTAssertEqual(["s1", "s2"], index.search("somebo", limit: 20).songs.map(\.id), "both songs of that name")
        XCTAssertEqual(["al1"], index.search("somebo", limit: 20).albums.map(\.id))
        XCTAssertEqual(["s1", "s2"], index.search("somebdy els", limit: 20).songs.map(\.id), "a small typo still matches")
        XCTAssertEqual(["s3"], index.search("addic", limit: 20).songs.map(\.id))
        XCTAssertEqual("s2", index.search("somebody else 1975", limit: 20).songs.first?.id, "title and artist together come first")
        XCTAssertTrue(index.search("zzzz", limit: 20).songs.isEmpty)
        // Album pages show at once from the catalog: songs in track order.
        let page = try XCTUnwrap(index.album("al1"))
        XCTAssertEqual(["s1"], page.song.map(\.id))
        XCTAssertEqual("Somebody Else", page.name)
        XCTAssertNil(index.album("missing"))
        XCTAssertNil(index.artist("ar1"), "catalogs saved before artist IDs: the page waits for the server")
        var withArtists = catalog
        withArtists.albums = catalog.albums.map { ServerCatalog.Album(id: $0.id, name: $0.name, artist: $0.artist, coverArt: $0.coverArt, year: $0.year,
                                                                     artistId: $0.id == "al1" ? "ar1" : "ar2") }
        XCTAssertEqual(["al1"], ServerCatalogIndex(withArtists).artist("ar1")?.album.map(\.id))
        // A catalog saved without artist IDs still loads.
        let old = #"{"artists":[],"albums":[{"id":"a","name":"A"}],"songs":[],"fetchedAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(ServerCatalog.self, from: Data(old.utf8)).albums.first?.artistId)
        let reloaded = try JSONDecoder().decode(ServerCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(catalog.songs.map(\.id), reloaded.songs.map(\.id))
        XCTAssertEqual(catalog.albums, reloaded.albums)
    }

    @MainActor
    func testDirectStreamingCoversTheFormatsIOSCanPlayAndHasTheSongsAddress() throws {
        for ext in ["mp3", "flac", "m4a", "aac", "wav", "MP3"] { XCTAssertTrue(StreamPlayer.canStream(fileExtension: ext), ext) }
        for ext in ["ogg", "opus", "oga"] { XCTAssertFalse(StreamPlayer.canStream(fileExtension: ext), "\(ext) is fetched in full first") }
        let album = try XCTUnwrap(try decode(SubsonicFixtures.album).album)
        let flac = try JSONDecoder().decode(ServerSong.self, from: Data(#"{"id":"f1","title":"Big","suffix":"flac","bitRate":900}"#.utf8))
        let song = ServerStream.shared.song(for: flac, account: account, quality: .mp3_192)
        XCTAssertEqual("", ServerStream.shared.streamFormat(of: song), "a converted stream's format comes from the server's reply")
        let original = ServerStream.shared.song(for: album.song[0], account: account, quality: .original)
        XCTAssertEqual("mp3", ServerStream.shared.streamFormat(of: original))
        // No client for this test account: the player falls back to fetching (which reports why).
        XCTAssertNil(ServerStream.shared.streamURL(for: song))
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
        // A 248 kbps MP3 streams unchanged even when converting is asked for (no wait for it).
        XCTAssertEqual(song.url, ServerStream.shared.song(for: remote, account: account, quality: .mp3_192).url)
        let flac = try JSONDecoder().decode(ServerSong.self, from: Data(#"{"id":"f2","title":"Big","suffix":"flac","bitRate":900}"#.utf8))
        let big = ServerStream.shared.song(for: flac, account: account, quality: .original)
        let small = ServerStream.shared.song(for: flac, account: account, quality: .mp3_192)
        XCTAssertNotEqual(big.url, small.url, "another quality is a separate cached file")
        XCTAssertTrue(small.url.lastPathComponent.hasSuffix(".mp3_192.mp3"), "a converted copy is saved as what it is")
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
