import Foundation
import CryptoKit
import Observation

struct LyricsTimingContext: Equatable, Identifiable {
    let songKey: String
    let sourceKey: String
    let label: String
    var id: String { songKey + ":" + sourceKey }

    init(song: Song, lyrics: SongLyrics) {
        func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        songKey = hash("\(song.id)|\(song.path)|\(song.durationMs)")
        // A changed provider record or changed lyrics text is a new version. Fetching the
        // same version again (including from the offline download) keeps its adjustment.
        sourceKey = hash(lyrics.sourceID + "\n" + (lyrics.text ?? ""))
        label = lyrics.origin == .file ? "File lyrics" : (lyrics.provider ?? "Online lyrics")
    }
}

struct LyricsTimingAdjustment: Codable, Equatable, Identifiable {
    let songKey: String
    let sourceKey: String
    let label: String
    let offsetMs: Int64
    let savedAt: Date
    var id: String { songKey + ":" + sourceKey }
}

/// Positive offsets delay lyrics. No source text or timestamps are rewritten.
@MainActor @Observable
final class LyricsTimingPreferences {
    private(set) var saved: [String: LyricsTimingAdjustment]
    private var preview: (context: LyricsTimingContext, offset: Int64)?
    @ObservationIgnored private let url: URL
    static let limit: Int64 = 30_000

    init(url: URL = LibraryPaths.supportFolder.appendingPathComponent("lyrics-timing.json")) {
        self.url = url
        saved = (try? JSONDecoder().decode([String: LyricsTimingAdjustment].self, from: Data(contentsOf: url))) ?? [:]
    }

    func offset(for context: LyricsTimingContext) -> Int64 {
        if preview?.context == context { return preview?.offset ?? 0 }
        return (saved[context.id]?.offsetMs ?? 0).clamped(-Self.limit, Self.limit)
    }

    func previous(for context: LyricsTimingContext) -> [LyricsTimingAdjustment] {
        saved.values.filter { $0.songKey == context.songKey && $0.sourceKey != context.sourceKey }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func preview(_ offset: Int64, for context: LyricsTimingContext) {
        preview = (context, offset.clamped(-Self.limit, Self.limit))
    }

    func endPreview(for context: LyricsTimingContext) {
        if preview?.context == context { preview = nil }
    }

    func save(_ offset: Int64, for context: LyricsTimingContext) throws {
        var next = saved
        next[context.id] = LyricsTimingAdjustment(songKey: context.songKey, sourceKey: context.sourceKey,
                                                label: context.label, offsetMs: offset.clamped(-Self.limit, Self.limit), savedAt: Date())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        saved = next
        endPreview(for: context)
    }

    nonisolated static func lyricsPosition(playbackMs: Int64, offsetMs: Int64) -> Int64 { playbackMs - offsetMs }
    nonisolated static func playbackPosition(lyricMs: Int64, offsetMs: Int64) -> Int64 { max(0, lyricMs + offsetMs) }
}
