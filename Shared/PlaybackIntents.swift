import AppIntents

// The widgets' playback buttons. Audio playback intents in both the app and the widget extension
// run in the app (started in the background if needed), so they control the real player; in the
// extension they only describe the button.

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or pause"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ERHU_WIDGET
        AppServices.shared.player.togglePlayPause()
        #endif
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next track"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ERHU_WIDGET
        AppServices.shared.player.skipNext()
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous track"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ERHU_WIDGET
        AppServices.shared.player.skipPrevious()
        #endif
        return .result()
    }
}
