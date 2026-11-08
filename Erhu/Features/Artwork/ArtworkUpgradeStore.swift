import Foundation
import CoreGraphics
import Observation

enum ArtworkUpgradeKind: String { case albums, artists }

struct ArtworkUpgrade: Identifiable {
    let target: ArtworkTarget
    let thumbnail: CGImage?
    let originalFacts: ArtworkImageFacts
    let candidate: ArtworkCandidate
    var id: String { target.id }
}

/// Immutable bytes for both sides of a comparison. A stale scan or changed provider image
/// cannot become an upgrade the user did not review.
struct ArtworkUpgradeReview: Identifiable {
    let upgrade: ArtworkUpgrade
    let original: Data
    let replacement: Data
    let originalFacts: ArtworkImageFacts
    let replacementFacts: ArtworkImageFacts
    var id: String { upgrade.id }

    init?(upgrade: ArtworkUpgrade, original: Data, replacement: Data) {
        guard let old = ArtworkImageFacts.inspect(original), old == upgrade.originalFacts,
              let next = ArtworkImageFacts.inspect(replacement), next == upgrade.candidate.image,
              ArtworkUpgradeMatch.isLarger(next, than: old), ArtworkUpgradeMatch.resembles(original, replacement) else { return nil }
        self.upgrade = upgrade; self.original = original; self.replacement = replacement
        originalFacts = old; replacementFacts = next
    }

    func matchesCurrentArtwork(_ data: Data?) -> Bool {
        data.flatMap(ArtworkImageFacts.inspect) == originalFacts
    }
}

@MainActor @Observable
final class ArtworkUpgradeStore {
    private(set) var results: [ArtworkUpgrade] = []
    private(set) var scanning = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var finished = false
    private(set) var skipped = 0
    private(set) var applying = false
    private(set) var applied = 0
    private(set) var applyTotal = 0
    private(set) var message: String?
    @ObservationIgnored private let checkpointFolder: URL?
    @ObservationIgnored private var kind: ArtworkUpgradeKind?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct Entry: Codable {
        let target: ArtworkTarget
        let originalFacts: ArtworkImageFacts?
        var candidate: ArtworkCandidate?
        func matches(_ other: ArtworkTarget) -> Bool {
            switch (target, other) {
            case (.album(let a), .album(let b)): a.id == b.id && a.title == b.title && a.artist == b.artist && a.year == b.year
            case (.artist(let a), .artist(let b)): a.id == b.id && a.name == b.name && a.artistKey == b.artistKey
            default: false
            }
        }
        var upgrade: ArtworkUpgrade? {
            guard let originalFacts, let candidate else { return nil }
            return ArtworkUpgrade(target: target, thumbnail: nil, originalFacts: originalFacts, candidate: candidate)
        }
    }

    init(checkpointFolder: URL? = LibraryPaths.supportFolder.appendingPathComponent("artwork-upgrade-progress", isDirectory: true)) {
        self.checkpointFolder = checkpointFolder
    }

    private func checkpoint(_ target: ArtworkTarget, kind: ArtworkUpgradeKind) -> ProgressFile<Entry> {
        ProgressFile(url: checkpointFolder?.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(target.id.replacingOccurrences(of: ":", with: "-") + ".json"))
    }

    private func targets(_ kind: ArtworkUpgradeKind, library: LibraryStore) -> [ArtworkTarget] {
        kind == .albums ? library.albums.map(ArtworkTarget.album)
            : library.artists.filter { $0.artworkPath != nil && !$0.isUnresolved }.map(ArtworkTarget.artist)
    }

    func restore(_ kind: ArtworkUpgradeKind, library: LibraryStore) {
        guard !scanning, !applying else { return }
        self.kind = kind
        let all = targets(kind, library: library)
        let entries = all.compactMap { target -> Entry? in
            guard let entry = checkpoint(target, kind: kind).load(), entry.matches(target) else { return nil }
            return entry
        }
        results = entries.compactMap(\.upgrade)
        checked = entries.count; total = all.count
        finished = checked > 0 && checked == total
    }

    func scan(_ kind: ArtworkUpgradeKind, library: LibraryStore, search: ArtworkSearch, restart: Bool = false) {
        guard !scanning, !applying else { return }
        self.kind = kind
        if restart, let folder = checkpointFolder?.appendingPathComponent(kind.rawValue) {
            try? FileManager.default.removeItem(at: folder)
        }
        results = []; checked = 0; skipped = 0; finished = false; scanning = true; message = nil
        let targets = self.targets(kind, library: library)
        total = targets.count
        task = Task {
            defer { scanning = false; task = nil }
            for target in targets {
                guard !Task.isCancelled else { return }
                let original = await Self.currentArtwork(target, library: library)
                guard !Task.isCancelled else { return }
                let facts = original.flatMap(ArtworkImageFacts.inspect)
                if let saved = checkpoint(target, kind: kind).load(), saved.matches(target), saved.originalFacts == facts {
                    if let upgrade = saved.upgrade { results.append(upgrade) }
                    checked += 1
                    continue
                }
                var best: ArtworkCandidate?
                var failedRequest = false
                if let original, let facts {
                    let candidates: [ArtworkCandidate]
                    switch target {
                    case .album(let album): candidates = await search.albumCovers(album: album.title, artist: album.artist, year: album.year)
                    case .artist(let artist): candidates = await search.artistPhotos(artist.name)
                    }
                    for candidate in candidates.sorted(by: { ($0.image?.width ?? 0) > ($1.image?.width ?? 0) }).prefix(12) {
                        guard !Task.isCancelled else { return }
                        guard let nextFacts = candidate.image, ArtworkUpgradeMatch.isLarger(nextFacts, than: facts) else { continue }
                        do {
                            let bytes = try await search.imageData(candidate)
                            let same = await Task.detached(priority: .utility) { ArtworkUpgradeMatch.resembles(original, bytes) }.value
                            guard !Task.isCancelled else { return }
                            if same { best = candidate; break }
                        } catch is CancellationError { return }
                        catch { skipped += 1; failedRequest = true }
                    }
                    if let best { results.append(ArtworkUpgrade(target: target, thumbnail: ArtworkImageFacts.thumbnail(original, maxPixels: 96), originalFacts: facts, candidate: best)) }
                } else { skipped += 1 }
                guard !Task.isCancelled else { return }
                if !failedRequest || best != nil {
                    do { try checkpoint(target, kind: kind).save(Entry(target: target, originalFacts: facts, candidate: best)) }
                    catch { message = "Couldn’t save progress: \(error.localizedDescription)"; return }
                }
                checked += 1
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            finished = true
        }
    }

    func remove(_ result: ArtworkUpgrade) {
        results.removeAll { $0.id == result.id }
        if let kind {
            do { try checkpoint(result.target, kind: kind).save(Entry(target: result.target, originalFacts: result.originalFacts, candidate: nil)) }
            catch { message = "Artwork saved, but the progress checkpoint couldn’t be updated: \(error.localizedDescription)" }
        }
    }

    /// The explicit batch action uses the same image, resolution, similarity and stale-artwork
    /// checks as an individual comparison, and saves each album before advancing to the next.
    func applyAll(library: LibraryStore, fetcher: ArtworkFetcherStore) {
        guard !scanning, !applying, !results.isEmpty else { return }
        let batch = results
        applying = true; applied = 0; applyTotal = batch.count; message = nil
        task = Task {
            var saved = 0
            defer {
                applying = false; task = nil
                message = "Upgraded \(saved) of \(batch.count) images. \(batch.count - saved) kept their current artwork."
            }
            for result in batch {
                guard !Task.isCancelled else { return }
                do {
                    let replacement = try await fetcher.search.imageData(result.candidate)
                    guard let original = await Self.currentArtwork(result.target, library: library),
                          let review = ArtworkUpgradeReview(upgrade: result, original: original, replacement: replacement),
                          !Task.isCancelled else { applied += 1; continue }
                    let success: Bool
                    switch result.target {
                    case .album(let album): success = await fetcher.applyCover(result.candidate, image: review.replacement, to: album)
                    case .artist(let artist): success = await fetcher.applyPhoto(result.candidate, image: review.replacement, to: artist)
                    }
                    if success { remove(result); saved += 1 }
                } catch { /* Keep failed or stale results available for retry and individual review. */ }
                applied += 1
            }
        }
    }

    func cancel() { task?.cancel() }

    static func currentArtwork(_ target: ArtworkTarget, library: LibraryStore) async -> Data? {
        let source: URL?
        switch target {
        case .album(let album): source = library.albumCoverSong[album.id]?.url
        case .artist(let artist): source = library.artist(artist.id)?.artworkPath.map { URL(fileURLWithPath: LibraryPaths.resolveImage($0)) }
        }
        return await Task.detached(priority: .utility) {
            guard let source else { return nil as Data? }
            switch target {
            case .album: return TagReader.artwork(source)
            case .artist: return try? Data(contentsOf: source)
            }
        }.value
    }
}
