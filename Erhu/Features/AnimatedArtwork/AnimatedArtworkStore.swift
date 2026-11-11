import Foundation
import Observation

struct SavedMotionCover: Codable, Equatable {
    let albumId: Int64
    let album: String
    let artist: String
    let catalogId: Int64
    let storefront: String
    var fileName: String
    var portraitFileName: String? = nil
    var compressedSquare: Bool? = nil
}

enum MotionCoverStatus: Equatable {
    case downloading, saved, notFound, failed(String)
    var label: String {
        switch self {
        case .downloading: String(localized: "Downloading…")
        case .saved: String(localized: "Downloaded · available offline")
        case .notFound: String(localized: "No matching motion cover found")
        case .failed(let message): message
        }
    }
}

@MainActor
@Observable
final class AnimatedArtworkStore {
    struct Saved: Codable, Equatable {
        var enabled = true
        var covers: [String: SavedMotionCover] = [:]
    }
    private(set) var saved: Saved
    private(set) var status: [Int64: MotionCoverStatus] = [:]
    let downloads = MotionCoverDownloads()
    var downloading: Int64? { downloads.current?.id }
    private(set) var compressing: Int64?
    private(set) var compressionPreview: MotionCompressionPreview?
    private(set) var compressionMessage: String?
    @ObservationIgnored private var compressionTask: Task<Void, Never>?
    @ObservationIgnored private let persistence = JSONStore<Saved>(name: "motion-covers.json")
    @ObservationIgnored private let service: AppleMotionService
    let availability: MotionCoverAvailability
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        let service = AppleMotionService()
        self.service = service
        availability = MotionCoverAvailability(checkpointURL: LibraryPaths.supportFolder.appendingPathComponent("motion-scan-progress.json")) { album in
            try await service.find(album: album.title, artist: album.artist, country: Locale.current.region?.identifier ?? "us")
        }
        saved = persistence.load() ?? Saved()
    }

    var enabled: Bool {
        get { saved.enabled }
        set { saved.enabled = newValue; persistence.saveNow(saved); onChange?() }
    }

    private static var folder: URL { LibraryPaths.supportFolder.appendingPathComponent("motion-covers", isDirectory: true) }

    func url(for song: Song, preferPortrait: Bool = false) -> URL? {
        // Album artist can differ from individual track credits; the album id is authoritative.
        guard enabled, let cover = saved.covers[String(song.albumId)] else { return nil }
        if preferPortrait, let name = cover.portraitFileName {
            let portrait = Self.folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: portrait.path) { return portrait }
        }
        let url = Self.folder.appendingPathComponent(cover.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func lockScreenURLs(for song: Song) -> [URL] {
        guard enabled, let cover = saved.covers[String(song.albumId)] else { return [] }
        return [cover.fileName, cover.portraitFileName].compactMap { $0 }
            .map { Self.folder.appendingPathComponent($0) }
    }

    var isBusy: Bool { downloads.isRunning || compressing != nil || compressionPreview != nil }

    func isDownloaded(_ album: Album) -> Bool {
        guard let cover = saved.covers[String(album.id)] else { return false }
        return FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(cover.fileName).path)
    }

    func pendingDownloads(in albums: [Album]) -> [Album] {
        MotionCoverDownloads.pending(albums,
            available: Set(albums.filter { availability.match(for: $0) != nil }.map(\.id)),
            downloaded: Set(albums.filter { isDownloaded($0) }.map(\.id)))
    }

    func download(_ album: Album) {
        enqueue([album])
    }

    func downloadAll(_ albums: [Album]) {
        enqueue(pendingDownloads(in: albums))
    }

    private func enqueue(_ albums: [Album]) {
        guard !isBusy, !availability.checking else { return }
        downloads.start(albums) { [weak self] album in
            guard let self else { throw CancellationError() }
            return try await self.downloadCover(album)
        }
    }

    private func downloadCover(_ album: Album) async throws -> MotionCoverDownloadResult {
        let retrying: Bool
        if case .failed? = status[album.id] { retrying = true } else { retrying = false }
        status[album.id] = .downloading
        var destination: URL?
        var portraitDestination: URL?
        do {
            try Task.checkCancellation()
            let country = Locale.current.region?.identifier ?? "us"
            let found: AppleMotionMatch?
            if !retrying, let cached = availability.freshMatch(for: album) { found = cached }
            else { found = try await service.find(album: album.title, artist: album.artist, country: country) }
            try Task.checkCancellation()
            guard let match = found else {
                status[album.id] = .notFound
                return .unavailable
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".mp4"
            let url = Self.folder.appendingPathComponent(name)
            destination = url
            try await service.download(match, to: url)
            var portraitName: String?
            if let master = match.portraitMaster, master != match.master {
                let name = UUID().uuidString + ".mp4"
                let target = Self.folder.appendingPathComponent(name)
                portraitDestination = target
                do {
                    let portrait = AppleMotionMatch(catalogId: match.catalogId, title: match.title, artist: match.artist,
                                                   storefront: match.storefront, master: master)
                    try await service.download(portrait, to: target)
                    portraitName = name
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    try Task.checkCancellation()
                    // A failed optional portrait must not discard the usable square cover.
                }
            }
            try Task.checkCancellation()
            _ = await MotionCoverPosterCache.shared.image(for: url)
            try Task.checkCancellation()
            let old = saved.covers[String(album.id)]
            var updated = saved
            updated.covers[String(album.id)] = SavedMotionCover(albumId: album.id, album: album.title, artist: album.artist,
                                                              catalogId: match.catalogId, storefront: match.storefront, fileName: name,
                                                              portraitFileName: portraitName)
            let manifest = LibraryPaths.supportFolder.appendingPathComponent("motion-covers.json")
            try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
            saved = updated
            onChange?()
            if let old { removeFiles(old) }
            status[album.id] = .saved
            return .saved
        } catch {
            if let destination { removeFile(destination) }
            if let portraitDestination { removeFile(portraitDestination) }
            if error is CancellationError || Task.isCancelled { status[album.id] = nil }
            else { status[album.id] = .failed(error.localizedDescription) }
            throw error
        }
    }

    func cancel() { downloads.stop(); compressionTask?.cancel() }

    func compress(_ album: Album) {
        guard !isBusy, !availability.checking,
              let cover = saved.covers[String(album.id)], cover.compressedSquare != true else { return }
        let original = Self.folder.appendingPathComponent(cover.fileName)
        let candidate = Self.folder.appendingPathComponent(UUID().uuidString + ".mp4")
        compressing = album.id; compressionMessage = nil
        compressionTask = Task {
            defer { compressing = nil; compressionTask = nil }
            do {
                let attributes = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let work = Task.detached(priority: .utility) {
                    try await MotionCoverCompressor.prepare(original, candidate: candidate)
                }
                try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                let current = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard current.fileSize == attributes.fileSize, current.contentModificationDate == attributes.contentModificationDate,
                      saved.covers[String(album.id)]?.fileName == cover.fileName else { throw MotionCompressionError.changed }
                _ = await MotionCoverPosterCache.shared.image(for: candidate)
                try Task.checkCancellation()
                compressionPreview = MotionCompressionPreview(albumId: album.id, title: album.title, original: original, candidate: candidate,
                    originalBytes: Int64(attributes.fileSize ?? 0), candidateBytes: Int64(try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
                    modified: attributes.contentModificationDate ?? .distantPast)
            } catch {
                removeFile(candidate)
                compressionMessage = error is CancellationError ? "Compression cancelled. Original kept." : error.localizedDescription
            }
        }
    }

    func discardCompression() {
        guard let preview = compressionPreview else { return }
        compressionPreview = nil
        removeFile(preview.candidate)
    }

    func acceptCompression() {
        guard let preview = compressionPreview, var cover = saved.covers[String(preview.albumId)] else { return }
        do {
            let attributes = try preview.original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard attributes.fileSize == Int(preview.originalBytes), attributes.contentModificationDate == preview.modified,
                  cover.fileName == preview.original.lastPathComponent else { throw MotionCompressionError.changed }
            cover.fileName = preview.candidate.lastPathComponent; cover.compressedSquare = true
            var updated = saved
            updated.covers[String(preview.albumId)] = cover
            // Atomically publish the manifest before releasing the previous artwork.
            let data = try JSONEncoder().encode(updated)
            let manifest = LibraryPaths.supportFolder.appending(path: "motion-covers.json")
            try data.write(to: manifest, options: .atomic)
            saved = updated
            compressionPreview = nil
            onChange?()
            removeFile(preview.original)
            compressionMessage = "Saved " + ByteCountFormatter.string(fromByteCount: preview.saving, countStyle: .file) + ". Portrait artwork was kept."
        } catch { compressionMessage = error.localizedDescription }
    }

    func remove(_ album: Album) {
        guard downloading != album.id, compressing != album.id, compressionPreview?.albumId != album.id else { return }
        if let old = saved.covers.removeValue(forKey: String(album.id)) {
            persistence.saveNow(saved)
            onChange?()
            removeFiles(old)
        }
        status[album.id] = nil
    }

    private func removeFiles(_ cover: SavedMotionCover) {
        for name in [cover.fileName, cover.portraitFileName].compactMap({ $0 }) {
            removeFile(Self.folder.appendingPathComponent(name))
        }
    }

    private func removeFile(_ video: URL) {
        MotionCoverPosterCache.shared.forget(video)
        try? FileManager.default.removeItem(at: MotionCoverPosterCache.posterURL(for: video))
        try? FileManager.default.removeItem(at: video)
    }

}
