import Foundation
import CoreGraphics
import Observation

enum ArtworkUpgradeKind { case albums, artists }

struct ArtworkUpgrade: Identifiable {
    let target: ArtworkTarget
    let thumbnail: CGImage?
    let originalFacts: ArtworkImageFacts
    let candidate: ArtworkCandidate
    var id: String { target.id }
}

@MainActor @Observable
final class ArtworkUpgradeStore {
    private(set) var results: [ArtworkUpgrade] = []
    private(set) var scanning = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var finished = false
    private(set) var skipped = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func scan(_ kind: ArtworkUpgradeKind, library: LibraryStore, search: ArtworkSearch) {
        guard !scanning else { return }
        results = []; checked = 0; skipped = 0; finished = false; scanning = true
        let targets: [ArtworkTarget] = kind == .albums ? library.albums.map(ArtworkTarget.album)
            : library.artists.filter { $0.artworkPath != nil && !$0.isUnresolved }.map(ArtworkTarget.artist)
        let covers = library.albumCoverSong
        total = targets.count
        task = Task {
            defer { scanning = false; task = nil }
            for target in targets {
                guard !Task.isCancelled else { return }
                let source: URL?
                switch target {
                case .album(let album): source = covers[album.id]?.url
                case .artist(let artist): source = artist.artworkPath.map { URL(fileURLWithPath: LibraryPaths.resolveImage($0)) }
                }
                let original: Data? = await Task.detached(priority: .utility) {
                    guard let source else { return nil }
                    switch target {
                    case .album: return TagReader.artwork(source)
                    case .artist: return try? Data(contentsOf: source)
                    }
                }.value
                guard !Task.isCancelled else { return }
                if let original, let facts = ArtworkImageFacts.inspect(original) {
                    let candidates: [ArtworkCandidate]
                    switch target {
                    case .album(let album): candidates = await search.albumCovers(album: album.title, artist: album.artist, year: album.year)
                    case .artist(let artist): candidates = await search.artistPhotos(artist.name)
                    }
                    var best: ArtworkCandidate?
                    for candidate in candidates.sorted(by: { ($0.image?.width ?? 0) > ($1.image?.width ?? 0) }).prefix(12) {
                        guard !Task.isCancelled else { return }
                        guard let nextFacts = candidate.image, ArtworkUpgradeMatch.isLarger(nextFacts, than: facts) else { continue }
                        do {
                            let bytes = try await search.imageData(candidate)
                            let same = await Task.detached(priority: .utility) { ArtworkUpgradeMatch.resembles(original, bytes) }.value
                            guard !Task.isCancelled else { return }
                            if same { best = candidate; break }
                        } catch is CancellationError { return }
                        catch { skipped += 1 }
                    }
                    if let best { results.append(ArtworkUpgrade(target: target, thumbnail: ArtworkImageFacts.thumbnail(original, maxPixels: 96), originalFacts: facts, candidate: best)) }
                } else { skipped += 1 }
                checked += 1
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            finished = true
        }
    }

    func remove(_ result: ArtworkUpgrade) { results.removeAll { $0.id == result.id } }
    func cancel() { task?.cancel() }
}
