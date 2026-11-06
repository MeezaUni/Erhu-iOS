import Foundation

/// An explicit bulk choice may resolve provider/edition ties, but still respects the user's
/// confidence threshold. Failed, reverted and completed entries are never silently reapplied.
enum BulkMetadataSelection {
    static func canSelect(_ item: RepairItem, minimumConfidence: Float) -> Bool {
        guard item.status == .needsReview || item.status == .noMatch else { return false }
        return item.savedCandidates.contains {
            $0.confidenceScore.isFinite && $0.confidenceScore >= minimumConfidence
                && isUsableTag($0.title) && isUsableTag($0.artist)
        }
    }

    static func best(for item: RepairItem, minimumConfidence: Float) -> MetadataCandidate? {
        guard item.status == .needsReview || item.status == .noMatch else { return nil }
        let candidates = item.savedCandidates
        let ranked = candidates.enumerated().filter {
            $0.element.confidenceScore.isFinite && $0.element.confidenceScore >= minimumConfidence
                && isUsableTag($0.element.title) && isUsableTag($0.element.artist)
        }.sorted { first, second in
            let a = first.element, b = second.element
            if a.confidenceScore != b.confidenceScore { return a.confidenceScore > b.confidenceScore }
            let album = item.diagnostics?.identity.album ?? item.song.album
            let firstAlbum = albumPositionTitle(a.album) == albumPositionTitle(album)
            let secondAlbum = albumPositionTitle(b.album) == albumPositionTitle(album)
            if firstAlbum != secondAlbum { return firstAlbum }
            let duration = item.diagnostics?.identity.durationMs ?? item.song.durationMs
            func delta(_ candidate: MetadataCandidate) -> Int64 {
                guard duration > 0, let length = candidate.durationMs, length > 0 else { return .max }
                return abs(length - duration)
            }
            if delta(a) != delta(b) { return delta(a) < delta(b) }
            return first.offset < second.offset
        }
        return ranked.first?.element
    }
}
