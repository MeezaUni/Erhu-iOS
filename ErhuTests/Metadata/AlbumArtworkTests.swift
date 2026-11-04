import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Erhu

final class AlbumArtworkTests: XCTestCase {
    func testWrongArtistRejectedAndAlternateEditionsNeedReview() throws {
        let query = AlbumArtworkQuery(album: "Discovery", artist: "Daft Punk", year: 2001)
        XCTAssertNil(AlbumArtworkMatching.match(query, album: "Discovery", artist: "Pink Floyd", year: 2001))
        let exact = try XCTUnwrap(AlbumArtworkMatching.match(query, album: "Discovery", artist: "Daft Punk", year: 2001))
        XCTAssertTrue(exact.review.isEmpty)
        let deluxe = try XCTUnwrap(AlbumArtworkMatching.match(query, album: "Discovery (Deluxe Edition)", artist: "Daft Punk", year: 2021))
        XCTAssertTrue(deluxe.review.contains("Different edition"))
        XCTAssertTrue(deluxe.review.contains("Different release year"))
        XCTAssertLessThan(deluxe.score, exact.score)
        let group = try XCTUnwrap(AlbumArtworkMatching.match(query, album: "Discovery", artist: "Daft Punk", year: 2001, groupCover: true))
        XCTAssertTrue(group.review.contains("Confirm release edition"))
        let unknown = AlbumArtworkQuery(album: "Discovery", artist: "Unknown Artist")
        XCTAssertFalse(try XCTUnwrap(AlbumArtworkMatching.match(unknown, album: "Discovery", artist: "Daft Punk")).review.isEmpty)
    }

    func testImageInspectionUsesDecodedDimensionsAndRejectsBadData() throws {
        let bytes = try image(width: 640, height: 800)
        let facts = try XCTUnwrap(ArtworkImageFacts.inspect(bytes))
        XCTAssertEqual(facts.width, 640)
        XCTAssertEqual(facts.height, 800)
        XCTAssertNil(ArtworkImageFacts.inspect(Data("not an image".utf8)))
        XCTAssertNil(ArtworkImageFacts.inspect(try image(width: 32, height: 32)))
        XCTAssertNil(ArtworkImageFacts.inspect(Data(repeating: 0, count: 3 * 1024 * 1024 + 1)))
    }

    func testSearchFiltersUnrelatedAlbumsAndReusesPersistentVerifiedResultsOffline() async throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ArtworkFixtureHTTP(image: try image(width: 640, height: 640))
        let cache = ArtworkCandidateCache(root: root)
        let results = await ArtworkSearch(client: client, cache: cache).albumCovers(album: "Discovery", artist: "Daft Punk", year: 2001)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.match?.artist, "Daft Punk")
        XCTAssertEqual(results.first?.image?.width, 640)
        XCTAssertTrue(results.first?.recommended == true)
        let requests = await client.requests
        XCTAssertFalse(requests.contains { $0.contains("wrong-cover") })
        await client.disableNetwork()
        let recreated = ArtworkCandidateCache(root: root)
        let cached = await ArtworkSearch(client: client, cache: recreated).albumCovers(album: "Discovery", artist: "Daft Punk", year: 2001)
        XCTAssertEqual(cached, results)
        let after = await client.requests
        XCTAssertEqual(after.count, requests.count)
    }

    func testArchiveNeverDownloadsBackOrUnapprovedImages() async throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ArtworkFixtureHTTP(image: try image(width: 640, height: 640), archive: true)
        let results = await ArtworkSearch(client: client, cache: ArtworkCandidateCache(root: root))
            .albumCovers(album: "Discovery", artist: "Daft Punk", year: 2001)
        XCTAssertFalse(results.isEmpty)
        let requests = await client.requests
        XCTAssertTrue(requests.contains { $0.contains("approved-front") })
        XCTAssertFalse(requests.contains { $0.contains("back-cover") || $0.contains("unapproved-cover") })
    }

    func testPreviewedImageCannotSilentlyChangeAfterCacheEviction() async throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try image(width: 640, height: 640)
        let different = try image(width: 640, height: 640, red: false)
        let candidate = ArtworkCandidate(url: "https://example.com/cover.jpg", source: "test", image: try XCTUnwrap(ArtworkImageFacts.inspect(original)))
        let cache = ArtworkCandidateCache(root: root)
        let checked = await cache.validate(candidate, client: ArtworkFixtureHTTP(image: different))
        XCTAssertNil(checked)
    }

    func testCacheBudgetIsBoundedAndNeverTouchesFilesOutsideItsDirectory() async throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("custom.jpg")
        let bytes = try image(width: 640, height: 640)
        try bytes.write(to: outside)
        let cacheRoot = root.appendingPathComponent("cache")
        let cache = ArtworkCandidateCache(root: cacheRoot, budget: 128)
        _ = await cache.validate(ArtworkCandidate(url: "https://example.com/cover.jpg", source: "test"), client: ArtworkFixtureHTTP(image: bytes))
        let files = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        XCTAssertLessThanOrEqual(size, 128)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image(width: Int, height: Int, red: Bool = true) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor ArtworkFixtureHTTP: HTTPClient {
    let image: Data
    private(set) var requests: [String] = []
    private var offline = false
    private let archive: Bool
    init(image: Data, archive: Bool = false) { self.image = image; self.archive = archive }
    func disableNetwork() { offline = true }
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        requests.append(url.absoluteString)
        if offline { throw URLError(.notConnectedToInternet) }
        let data: Data
        if url.host == "example.com" { data = image }
        else if url.host == "itunes.apple.com" {
            data = Data(#"{"results":[{"collectionName":"Discovery","artistName":"Daft Punk","releaseDate":"2001-03-12","artworkUrl100":"https://example.com/cover.jpg"},{"collectionName":"Discovery","artistName":"Pink Floyd","artworkUrl100":"https://example.com/wrong-cover.jpg"}]}"#.utf8)
        } else if url.path == "/ws/2/release" {
            data = archive
                ? Data(#"{"releases":[{"id":"11111111-1111-1111-1111-111111111111","title":"Discovery","date":"2001-03-12","artist-credit":[{"name":"Daft Punk"}]}]}"#.utf8)
                : Data(#"{"releases":[]}"#.utf8)
        } else if url.host == "coverartarchive.org" {
            data = Data(#"{"images":[{"image":"https://example.com/approved-front.jpg","front":true,"approved":true},{"image":"https://example.com/back-cover.jpg","front":false,"approved":true},{"image":"https://example.com/unapproved-cover.jpg","front":true,"approved":false}]}"#.utf8)
        }
        else if url.path == "/ws/2/release-group" { data = Data(#"{"release-groups":[]}"#.utf8) }
        else { data = Data(#"{"data":[]}"#.utf8) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
