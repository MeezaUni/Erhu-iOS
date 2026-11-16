import AVFoundation
import Foundation

/// Plays a song straight from a music server while it downloads, so it starts at once instead of
/// waiting for the whole file. Used only for streamed songs that aren't in the cache yet; the
/// equalizer, transitions and visualizer need the full file and [AudioEngine], which plays them
/// once they are cached. One song at a time.
@MainActor
final class StreamPlayer {
    /// The entry this player is playing (nil: idle).
    private(set) var entryId: UUID?
    /// Playback actually started or resumed (after any initial buffering).
    var onPlaying: ((UUID) -> Void)?
    /// The song played to its end.
    var onFinished: ((UUID) -> Void)?
    /// The song couldn't be played; the message says why.
    var onFailed: ((UUID, String) -> Void)?
    /// The system paused playback (a call, another app) without being asked to here.
    var onPausedBySystem: ((UUID) -> Void)?

    var volume: Float = 1 { didSet { player?.volume = volume } }

    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var wantsToPlay = false

    /// Formats iOS's player streams; others (Ogg Vorbis, Opus) are fetched in full first.
    static func canStream(fileExtension ext: String) -> Bool {
        !["ogg", "oga", "opus", "spx"].contains(ext.lowercased())
    }

    /// The media type for [ext], so the player knows the format of a URL without an extension.
    private static func mimeType(for ext: String) -> String? {
        switch ext.lowercased() {
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "m4a", "alac", "mp4", "m4b": "audio/mp4"
        case "aac": "audio/aac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: nil
        }
    }

    func play(entryId: UUID, url: URL, fileExtension: String, positionMs: Int64, startPlaying: Bool) {
        stop()
        self.entryId = entryId
        var options: [String: Any] = [:]
        if let type = Self.mimeType(for: fileExtension) { options[AVURLAssetOverrideMIMETypeKey] = type }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        // Start as soon as a little is buffered rather than waiting to be sure of no stall.
        item.preferredForwardBufferDuration = 0
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = volume
        self.player = player
        observe(player: player, item: item, entryId: entryId)
        if positionMs > 0 {
            player.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        wantsToPlay = startPlaying
        if startPlaying { player.play() }
    }

    func pause() {
        wantsToPlay = false
        player?.pause()
    }

    func resume() {
        wantsToPlay = true
        player?.play()
    }

    func seek(toMs positionMs: Int64) {
        player?.seek(to: CMTime(value: max(positionMs, 0), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        observations.forEach { $0.invalidate() }
        observations = []
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        entryId = nil
        wantsToPlay = false
    }

    /// The position of [entryId]'s song, in milliseconds.
    func positionMs(of entryId: UUID) -> Int64? {
        guard entryId == self.entryId, let player else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(seconds * 1000) : nil
    }

    private func observe(player: AVPlayer, item: AVPlayerItem, entryId: UUID) {
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self, self.entryId == entryId else { return }
                switch status {
                case .playing: self.onPlaying?(entryId)
                case .paused:
                    // Paused without being asked here, before the end: the system interrupted.
                    if self.wantsToPlay, item.status == .readyToPlay,
                       item.currentTime() < item.duration - CMTime(value: 1, timescale: 2) {
                        self.wantsToPlay = false
                        self.onPausedBySystem?(entryId)
                    }
                default: break
                }
            }
        })
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.entryId == entryId, status == .failed else { return }
                self.stop()
                self.onFailed?(entryId, message ?? String(localized: "The server didn't send audio for this song."))
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.entryId == entryId else { return }
                self.stop()
                self.onFinished?(entryId)
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self, self.entryId == entryId else { return }
                self.stop()
                self.onFailed?(entryId, message ?? String(localized: "The server didn't send audio for this song."))
            }
        })
    }
}
