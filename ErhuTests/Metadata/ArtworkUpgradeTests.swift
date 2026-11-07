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
}
