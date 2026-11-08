import Foundation

/// The small manifest records order and pending work; each track's potentially large lookup
/// diagnostics are stored separately, so one completion never rewrites the whole library.
struct FixTagsProgress {
    struct Manifest: Codable {
        var version = 1
        var songs: [Song]
        var libraryChecked: [Int64: String]
        var followsLibrary: Bool
        var started: Bool
        var autoFillRemaining: [Int64]?
        var scope: Set<Int64>
        var missingScanInProgress: Bool
        var missingChecked: Int
        var missingTotal: Int
    }
    struct MissingCheck: Codable, Sendable {
        let song: Song
        let stamp: ProgressFileStamp
        let fields: [String]
        let missing: [MetadataField]
    }
    let manifest: ProgressFile<Manifest>
    private var folder: URL? { manifest.url?.appendingPathExtension("items") }
    func item(_ id: Int64) -> ProgressFile<RepairItem> {
        ProgressFile(url: folder?.appendingPathComponent("\(id).json"))
    }
    func missing(_ id: Int64) -> ProgressFile<MissingCheck> {
        ProgressFile(url: manifest.url?.appendingPathExtension("checks").appendingPathComponent("\(id).json"))
    }
    func clear() {
        manifest.remove()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let checks = manifest.url?.appendingPathExtension("checks") { try? FileManager.default.removeItem(at: checks) }
    }
}
