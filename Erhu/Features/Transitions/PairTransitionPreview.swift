import AVFoundation
import Observation

/// Audition never replaces the user's queue, seek position, history or transition settings.
@MainActor
@Observable
final class PairTransitionPreview {
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var error: String?
    private(set) var renderedPositionMs: Double?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var engine: AudioEngine?
    @ObservationIgnored private var setup: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private var resumeEntry: UUID?

    func play(pair: StudioPair, timing: PairTransitionTiming, player: PlayerController, sound: SoundSettings) {
        stop()
        error = nil
        self.player = player
        if player.state.isPlaying {
            resumeEntry = player.state.currentEntry?.id
            player.pause()
        }
        isPreparing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                self.error = "Preview unavailable: the audio output could not be activated."
                stop()
                return
            }
            if self.engine == nil {
                let engine = AudioEngine()
                self.engine = engine
                setup = Task { await engine.setUp() }
            }
            await setup?.value
            guard !Task.isCancelled else { return }
            guard let engine = self.engine else { return }
            engine.eqKernel.apply(sound)
            engine.volume = player.engine.volume
            engine.onEntryFinished = { [weak self] _ in self?.stop() }
            engine.onConfigurationChange = { [weak self] in self?.stop(resume: false) }
            do {
                try engine.previewTransition(outgoing: pair.from.song.url, incoming: pair.to.song.url, timing: timing)
                isPreparing = false
                isPlaying = true
                positionTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.isPlaying else { return }
                        self.renderedPositionMs = self.engine?.previewPositionMs()
                        try? await Task.sleep(for: .milliseconds(33))
                    }
                }
            } catch {
                self.error = "Preview unavailable: the files or transition audio processor could not be opened."
                stop()
            }
        }
    }

    func positionMs() -> Double? { isPlaying ? renderedPositionMs : nil }

    func stop(resume: Bool = true) {
        positionTask?.cancel()
        positionTask = nil
        renderedPositionMs = nil
        task?.cancel()
        task = nil
        engine?.stopAll()
        isPreparing = false
        isPlaying = false
        let entry = resumeEntry
        resumeEntry = nil
        if resume, let entry, let player, player.state.currentEntry?.id == entry, !player.state.isPlaying { player.play() }
    }
}
