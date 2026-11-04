import Foundation
import XCTest
@testable import Erhu

final class KeylessArtworkTests: XCTestCase {
    @MainActor func testKeylessSourcesRemainAndRetiredSelectionFallsBackSafely() throws {
        XCTAssertEqual(MetadataSources.options.map(\.key), ["ALL", "iTunes", "MusicBrainz", "Deezer"])
        let old = Data(#"{"source":"Last.fm"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FixTagsStore.Settings.self, from: old).source, "ALL")
        let existing = Data(#"{"source":"iTunes"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FixTagsStore.Settings.self, from: existing).source, "iTunes")
    }
    func testFailedKeylessLookupsReturnNoInventedArtworkAndNeverContactRetiredServices() async {
        let client = KeylessHTTP()
        let result = await ArtworkSearch(client: client).albumCovers(album: "Album", artist: "Artist")
        XCTAssertTrue(result.isEmpty)
        let hosts = await client.hosts
        XCTAssertTrue(hosts.contains("itunes.apple.com"))
        XCTAssertTrue(hosts.contains("musicbrainz.org"))
        XCTAssertTrue(hosts.contains("api.deezer.com"))
        XCTAssertFalse(hosts.contains { $0.contains("last.fm") || $0.contains("audioscrobbler") || $0.contains("fanart") || $0.contains("discogs") })
    }
    func testCommonsRequiresLicenseAndCreatorAndKeepsAttribution() throws {
        let permitted = try image(license: "CC BY-SA 4.0", url: "https://creativecommons.org/licenses/by-sa/4.0/", author: "<a>Jane &amp; Co</a>")
        let candidates = CommonsArtworkSearch.candidates(permitted)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].credit?.author, "Jane & Co")
        XCTAssertEqual(candidates[0].credit?.license, "CC BY-SA 4.0")
        XCTAssertTrue(candidates[0].credit?.page.absoluteString.contains("commons.wikimedia.org") == true)
        XCTAssertTrue(CommonsArtworkSearch.candidates(try image(license: "All rights reserved", url: "", author: "Jane")).isEmpty)
        XCTAssertTrue(CommonsArtworkSearch.candidates(try image(license: "CC BY 4.0", url: "https://creativecommons.org/licenses/by/4.0/", author: "")).isEmpty)
        XCTAssertTrue(CommonsArtworkSearch.candidates(try image(license: "CC BY 4.0", url: "https://example.com/license", author: "Jane")).isEmpty)
    }
    func testCommonsDoesNotImportNonCommonsFairUseImages() throws {
        let data = try image(license: "CC BY 4.0", url: "https://creativecommons.org/licenses/by/4.0/", author: "Jane", imageHost: "upload.example.org")
        XCTAssertTrue(CommonsArtworkSearch.candidates(data).isEmpty)
    }
    private func image(license: String, url: String, author: String, imageHost: String = "upload.wikimedia.org") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["query": ["pages": ["1": ["title": "File:Portrait.jpg", "imageinfo": [[
            "mime": "image/jpeg", "url": "https://\(imageHost)/portrait.jpg", "descriptionurl": "https://commons.wikimedia.org/wiki/File:Portrait.jpg",
            "extmetadata": ["LicenseShortName": ["value": license], "LicenseUrl": ["value": url], "Artist": ["value": author]]
        ]]]]]])
    }
}
private actor KeylessHTTP: HTTPClient {
    private(set) var hosts: [String] = []
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        hosts.append(url.host ?? "")
        XCTAssertNil(headers["Authorization"])
        XCTAssertFalse(url.query?.contains("api_key") == true)
        return (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
}
