import Foundation

struct ProgressFileStamp: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    let modified: Date?
    init(_ song: Song) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: song.url.path)
        path = song.path
        size = (attributes?[.size] as? NSNumber)?.int64Value ?? song.fileSize
        modified = attributes?[.modificationDate] as? Date
    }
}

/// Small atomic checkpoints are written after an item finishes, rather than waiting for
/// a background notification that force-quitting the app may never deliver.
struct ProgressFile<Value: Codable>: Sendable {
    let url: URL?
    func load() -> Value? {
        guard let url, let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: bytes)
    }
    func save(_ value: Value) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    func remove() { if let url { try? FileManager.default.removeItem(at: url) } }
}
