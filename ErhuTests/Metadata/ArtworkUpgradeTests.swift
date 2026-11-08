import XCTest
import UIKit
@testable import Erhu

final class ArtworkUpgradeTests: XCTestCase {
    private func image(size: CGFloat, variant: Bool = false, quality: CGFloat = 0.9) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).jpegData(withCompressionQuality: quality) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.orange.setFill()
            context.fill(CGRect(x: size * (variant ? 0.6 : 0.1), y: size * 0.2, width: size * 0.25, height: size * 0.6))
        }
    }

    func testSameArtworkAtDifferentResolutionAndCompressionIsRecognized() throws {
        let small = image(size: 150, quality: 0.75), large = image(size: 1200)
        XCTAssertTrue(ArtworkUpgradeMatch.resembles(small, large))
        XCTAssertTrue(ArtworkUpgradeMatch.isLarger(try XCTUnwrap(ArtworkImageFacts.inspect(large)), than: try XCTUnwrap(ArtworkImageFacts.inspect(small))))
        XCTAssertFalse(ArtworkUpgradeMatch.resembles(small, image(size: 1200, variant: true)), "Different art must not be presented as the same image")
        XCTAssertFalse(ArtworkUpgradeMatch.resembles(small, Data("invalid".utf8)))
    }

    func testSearchDoesNotOfferAnUpgradeThatTheSaveLimitWouldUndo() {
        let original = ArtworkImageFacts(width: 1400, height: 1400, digest: "old")
        let candidate = ArtworkImageFacts(width: 3000, height: 3000, digest: "new")
        XCTAssertFalse(ArtworkUpgradeMatch.isLarger(candidate, than: original))
        XCTAssertFalse(ArtworkUpgradeMatch.isLarger(ArtworkImageFacts(width: 600, height: 1000, digest: "crop"),
                                                  than: ArtworkImageFacts(width: 100, height: 100, digest: "old")))
    }

    func testComparisonUsesTheActualOriginalAndApprovedReplacementForAlbumsAndArtists() throws {
        let original = image(size: 150, quality: 0.75), replacement = image(size: 1200)
        let old = try XCTUnwrap(ArtworkImageFacts.inspect(original)), next = try XCTUnwrap(ArtworkImageFacts.inspect(replacement))
        let targets: [ArtworkTarget] = [
            .album(Album(id: 1, title: "Album", artist: "Artist", artistId: 2, songCount: 2, year: 2026)),
            .artist(Artist(id: 2, name: "Artist", songCount: 2, albumCount: 1, artworkPath: "artist.jpg"))
        ]
        for target in targets {
            let candidate = ArtworkCandidate(url: "https://example.com/image.jpg", source: "Artist catalogue", image: next)
            let upgrade = ArtworkUpgrade(target: target, thumbnail: nil, originalFacts: old, candidate: candidate)
            let review = try XCTUnwrap(ArtworkUpgradeReview(upgrade: upgrade, original: original, replacement: replacement))
            XCTAssertEqual(review.id, target.id)
            XCTAssertEqual(review.original, original)
            XCTAssertEqual(review.replacement, replacement)
            XCTAssertEqual(review.originalFacts.resolution, "150 × 150")
            XCTAssertEqual(review.replacementFacts.resolution, "1200 × 1200")
            XCTAssertTrue(review.matchesCurrentArtwork(original))
            XCTAssertFalse(review.matchesCurrentArtwork(image(size: 150, variant: true)))
            XCTAssertFalse(review.matchesCurrentArtwork(nil))
        }
    }

    func testComparisonRejectsStaleOriginalChangedProviderBytesAndDifferentArt() throws {
        let original = image(size: 150), replacement = image(size: 1200)
        let target = ArtworkTarget.artist(Artist(id: 2, name: "Artist", songCount: 2, albumCount: 1, artworkPath: "artist.jpg"))
        var candidate = ArtworkCandidate(url: "https://example.com/image.jpg", source: "Catalogue", image: try XCTUnwrap(ArtworkImageFacts.inspect(replacement)))
        let old = try XCTUnwrap(ArtworkImageFacts.inspect(original))
        let upgrade = ArtworkUpgrade(target: target, thumbnail: nil, originalFacts: old, candidate: candidate)
        XCTAssertNil(ArtworkUpgradeReview(upgrade: upgrade, original: image(size: 150, quality: 0.65), replacement: replacement))
        XCTAssertNil(ArtworkUpgradeReview(upgrade: upgrade, original: original, replacement: image(size: 1200, quality: 0.65)))
        let different = image(size: 1200, variant: true)
        candidate.image = ArtworkImageFacts.inspect(different)
        XCTAssertNil(ArtworkUpgradeReview(upgrade: ArtworkUpgrade(target: target, thumbnail: nil, originalFacts: old, candidate: candidate),
                                        original: original, replacement: different))
    }
    @MainActor
    func testApplyAllRestoresMatchesAndKeepsArtworkThatChangedAfterTheScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (1...2).map { _ in LibraryPaths.musicFolder.appendingPathComponent(UUID().uuidString + ".mp3") }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let database = try LibraryDatabase.inMemory()
        for (offset, file) in files.enumerated() {
            let id = Int64(offset + 1)
            try TagFixtures.mp3(v4: true).write(to: file)
            var edit = TagWriteRequest()
            edit.title = "Song \(id)"; edit.album = "Album \(id)"; edit.artist = "Artist"; edit.artwork = image(size: 150)
            try TagWriter.write(edit, to: file)
            try database.db.execute("INSERT INTO albums (id, title, artist, artist_id, song_count, year) VALUES (?, ?, 'Artist', 1, 1, 2026)", [id, "Album \(id)"])
            try database.db.execute("""
                INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, year, date_modified)
                VALUES (?, ?, 'Artist', ?, 1, ?, 180000, ?, ?, 2026, 0)
                """, [id, "Song \(id)", "Album \(id)", id, file.lastPathComponent, file.lastPathComponent])
        }
        let library = LibraryStore(database: database)
        let client = UpgradeBatchHTTP(image: image(size: 1000))
        let search = ArtworkSearch(client: client, cache: ArtworkCandidateCache(root: root.appendingPathComponent("cache")))
        let checkpoint = root.appendingPathComponent("progress")
        let first = ArtworkUpgradeStore(checkpointFolder: checkpoint)
        first.scan(.albums, library: library, search: search)
        for _ in 0..<500 {
            if !first.scanning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(first.scanning)
        XCTAssertEqual(first.results.count, 2)
        let reopened = ArtworkUpgradeStore(checkpointFolder: checkpoint)
        reopened.restore(.albums, library: library)
        XCTAssertEqual(reopened.results.count, 2, "Pending upgrades must survive leaving the page and reopening the app")
        var changed = TagWriteRequest(); changed.artwork = image(size: 150, variant: true)
        try TagWriter.write(changed, to: files[1])
        let kept = try XCTUnwrap(TagReader.artwork(files[1]))
        let fetcher = ArtworkFetcherStore(library: library, service: MetadataService(client: client), search: search, checkpointURL: nil)
        reopened.applyAll(library: library, fetcher: fetcher)
        for _ in 0..<500 {
            if !reopened.applying && !library.isScanning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(reopened.applying)
        XCTAssertEqual(ArtworkImageFacts.inspect(try XCTUnwrap(TagReader.artwork(files[0])))?.width, 1000)
        XCTAssertEqual(TagReader.artwork(files[1]), kept, "A changed original must never be overwritten by Apply to all")
        XCTAssertEqual(reopened.results.map(\.id), ["album:2"])
        let saved = try Data(contentsOf: checkpoint.appendingPathComponent("albums/album-1.json"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: saved) as? [String: Any])?["candidate"], "An applied upgrade must not return after relaunch")
    }

}


private struct UpgradeBatchHTTP: HTTPClient {
    let image: Data
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let bytes: Data
        let type: String
        if url.host == "images.example" { bytes = image; type = "image/jpeg" }
        else {
            type = "application/json"
            let rows: [[String: Any]] = (1...2).map {
                ["collectionName": "Album \($0)", "artistName": "Artist", "releaseDate": "2026-01-01T00:00:00Z",
                 "artworkUrl100": "https://images.example/\($0)/100x100bb.jpg"]
            }
            let body: [String: Any] = url.host == "itunes.apple.com" ? ["results": rows]
                : ["data": [], "releases": [], "release-groups": [], "artists": [], "query": ["pages": [:]]]
            bytes = try JSONSerialization.data(withJSONObject: body)
        }
        return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
    }
}
