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
    /// Enough of the song is buffered (all of it, or a minute ahead) that other downloads can
    /// start without making it stall. Called once per song.
    var onBufferedEnough: ((UUID) -> Void)?
    /// Playback stopped to wait for more of the song (the connection fell behind or dropped).
    var onWaiting: ((UUID) -> Void)?

    var volume: Float = 1 { didSet { player?.volume = volume } }

    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var wantsToPlay = false
    private var reportedBuffered = false
    /// The next song, connected and buffering ahead while paused, so skipping to it starts at once.
    private var prepared: (entryId: UUID, url: URL, player: AVPlayer, item: AVPlayerItem)?

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

    private static func makeItem(url: URL, fileExtension: String) -> AVPlayerItem {
        var options: [String: Any] = [:]
        if let type = mimeType(for: fileExtension) { options[AVURLAssetOverrideMIMETypeKey] = type }
        return AVPlayerItem(asset: AVURLAsset(url: url, options: options))
    }

    /// Connects to [url] and buffers its start while paused, for [play] of the same entry to start
    /// without waiting. Replaces an earlier prepared song.
    func prepare(entryId: UUID, url: URL, fileExtension: String) {
        if prepared?.entryId == entryId, prepared?.url == url { return }
        discardPrepared()
        let item = Self.makeItem(url: url, fileExtension: fileExtension)
        // Enough to start smoothly; the rest streams once it plays.
        item.preferredForwardBufferDuration = 20
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 0
        prepared = (entryId, url, player, item)
    }

    func discardPrepared() {
        prepared?.player.pause()
        prepared?.player.replaceCurrentItem(with: nil)
        prepared = nil
    }

    func play(entryId: UUID, url: URL, fileExtension: String, positionMs: Int64, startPlaying: Bool) {
        stop()
        self.entryId = entryId
        let item: AVPlayerItem, player: AVPlayer
        if let ready = prepared, ready.entryId == entryId, ready.url == url, ready.item.status != .failed {
            // Prepared while the previous song played: already connected and buffered.
            (item, player) = (ready.item, ready.player)
            item.preferredForwardBufferDuration = 0
            prepared = nil
        } else {
            if prepared?.entryId == entryId { discardPrepared() }
            item = Self.makeItem(url: url, fileExtension: fileExtension)
            player = AVPlayer(playerItem: item)
        }
        // If the connection falls behind, wait for more instead of stopping (see [play]).
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volume
        self.player = player
        observe(player: player, item: item, entryId: entryId)
        if positionMs > 0 {
            player.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        wantsToPlay = startPlaying
        // Start at once with what has arrived; later stalls wait to refill rather than stutter.
        if startPlaying { player.playImmediately(atRate: 1) }
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
        reportedBuffered = false
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
                case .waitingToPlayAtSpecifiedRate: if self.wantsToPlay { self.onWaiting?(entryId) }
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
        observations.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            let ahead = item.loadedTimeRanges.map(\.timeRangeValue).map { CMTimeRangeGetEnd($0).seconds }.max() ?? 0
            let now = item.currentTime().seconds
            let duration = item.duration.seconds
            Task { @MainActor in
                guard let self, self.entryId == entryId, !self.reportedBuffered else { return }
                let complete = duration.isFinite && duration > 0 && ahead >= duration - 1
                if complete || (now.isFinite && ahead - now >= 60) {
                    self.reportedBuffered = true
                    self.onBufferedEnough?(entryId)
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
