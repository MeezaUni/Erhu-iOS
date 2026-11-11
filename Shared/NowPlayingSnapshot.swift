import Foundation

/// What the Home Screen widgets show: the playing song, where it is, and what comes next. The app
/// writes it into the shared App Group folder whenever playback changes; the widget reads it.
struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    struct Track: Codable, Equatable, Sendable {
        var title: String
        var artist: String
    }

    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// The position when the snapshot was taken ([capturedAt]); while playing it moves on from there.
    var positionMs: Int64
    var durationMs: Int64
    var capturedAt: Date
    /// The cover's file name in the shared folder, if the song has one.
    var artworkFile: String?
    var upNext: [Track]

    /// Where playback is at [date].
    func position(at date: Date) -> Int64 {
        guard isPlaying else { return positionMs }
        let moved = Int64(date.timeIntervalSince(capturedAt) * 1000)
        return min(max(positionMs + moved, 0), max(durationMs, 0))
    }

    /// When the song started, counted back from the position (for a live progress bar).
    var startDate: Date { capturedAt.addingTimeInterval(-Double(positionMs) / 1000) }
    var endDate: Date { startDate.addingTimeInterval(Double(max(durationMs, 1)) / 1000) }

    /// The same song, state and queue, with the position where it is expected to be (a playing
    /// song's position moving on by itself is not a change).
    func showsSameAs(_ other: NowPlayingSnapshot) -> Bool {
        guard title == other.title, artist == other.artist, album == other.album, isPlaying == other.isPlaying,
              durationMs == other.durationMs, artworkFile == other.artworkFile, upNext == other.upNext else { return false }
        return abs(position(at: other.capturedAt) - other.positionMs) < 2_000
    }
}

/// The folder the app and its widgets share, and the files in it.
enum WidgetShared {
    static let kind = "ErhuNowPlaying"
    static let snapshotFileName = "now-playing.json"

    /// The App Group to use. Signed in Xcode it is "group.com.erhu". AltStore and SideStore sign
    /// with a free Apple ID and add the team to every identifier ("com.erhu.ABCDE12345" and
    /// "group.com.erhu.ABCDE12345"), so the group is also tried after the app's own identifier.
    static var appGroupCandidates: [String] {
        var bundleId = Bundle.main.bundleIdentifier ?? "com.erhu"
        // The widget extension's identifier is the app's plus ".widgets".
        if Bundle.main.bundlePath.hasSuffix(".appex"), let dot = bundleId.lastIndex(of: ".") {
            bundleId = String(bundleId[..<dot])
        }
        var candidates = ["group.\(bundleId)", "group.com.erhu"]
        if bundleId.hasPrefix("com.erhu.") {
            // An installer may also put the team in front: "ABCDE12345.com.erhu".
            candidates.append("group.com.erhu.\(bundleId.dropFirst("com.erhu.".count))")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The shared folder, or nil when the app was installed without its App Group.
    static let containerURL: URL? = appGroupCandidates.lazy
        .compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        .first

    static func load() -> NowPlayingSnapshot? {
        guard let url = containerURL?.appendingPathComponent(snapshotFileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    static func artworkURL(_ snapshot: NowPlayingSnapshot) -> URL? {
        guard let name = snapshot.artworkFile else { return nil }
        return containerURL?.appendingPathComponent(name)
    }
}
