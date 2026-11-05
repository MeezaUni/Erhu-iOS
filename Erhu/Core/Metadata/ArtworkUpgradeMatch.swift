import Foundation
import CoreGraphics

/// Conservative whole-image comparison: do not treat a new artist portrait or a different
/// cover edition as a resolution upgrade. The listener still reviews the full image.
enum ArtworkUpgradeMatch {
    static func isLarger(_ candidate: ArtworkImageFacts, than original: ArtworkImageFacts) -> Bool {
        let scale = min(1, Double(TagWriter.maxArtworkPixels) / Double(max(candidate.width, candidate.height)))
        return Double(candidate.width) * scale >= Double(original.width) * 1.25 &&
        Double(candidate.height) * scale >= Double(original.height) * 1.25 &&
        abs(Double(candidate.width) / Double(candidate.height) - Double(original.width) / Double(original.height)) < 0.025
    }

    static func resembles(_ original: Data, _ candidate: Data) -> Bool {
        guard let a = signature(original), let b = signature(candidate) else { return false }
        let difference = zip(a, b).map { abs(Double($0) - Double($1)) / 255 }.reduce(0, +) / Double(a.count)
        // Compare spatial colours as well as edges; a matching silhouette alone is insufficient.
        guard difference < 0.065 else { return false }
        var differentEdges = 0
        for y in 0..<16 {
            for x in 0..<15 {
                func light(_ bytes: [UInt8], _ x: Int) -> Int {
                    let i = (y * 16 + x) * 3
                    return Int(bytes[i]) * 3 + Int(bytes[i + 1]) * 6 + Int(bytes[i + 2])
                }
                let da = light(a, x + 1) - light(a, x)
                let db = light(b, x + 1) - light(b, x)
                if abs(da) > 40 && abs(db) > 40 && (da > 0) != (db > 0) { differentEdges += 1 }
            }
        }
        return differentEdges <= 5
    }

    private static func signature(_ data: Data) -> [UInt8]? {
        guard let image = ArtworkImageFacts.thumbnail(data, maxPixels: 64) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard success else { return nil }
        return pixels.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }
}
