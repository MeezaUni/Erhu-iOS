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
}
