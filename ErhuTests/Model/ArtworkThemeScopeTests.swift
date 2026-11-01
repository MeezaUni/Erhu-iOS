import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Erhu

final class ArtworkThemeScopeTests: XCTestCase {
    private struct Snapshot: Equatable {
        let page: AppPalette
        let playback: AppPalette
    }

    @MainActor @Observable
    private final class State {
        var artistVisible = false
        var playback: AppPalette
        var backgroundSnapshots: [Snapshot] = []
        var artistSnapshots: [Snapshot] = []
        init(playback: AppPalette) { self.playback = playback }
    }

    private struct Probe: View {
        let record: (Snapshot) -> Void
        @Environment(\.palette) private var page
        @Environment(\.playbackPalette) private var playback
        var body: some View {
            Color.clear.frame(height: 30)
                .onChange(of: Snapshot(page: page, playback: playback), initial: true) { _, value in record(value) }
        }
    }

    private struct Harness: View {
        let state: State
        let photo: URL
        var body: some View {
            VStack {
                Probe { state.backgroundSnapshots.append($0) }
                if state.artistVisible {
                    Probe { state.artistSnapshots.append($0) }.collectionArtworkTheme(.image(photo))
                }
            }
            .environment(\.palette, state.playback)
            .environment(\.playbackPalette, state.playback)
        }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Theme scopes did not update")
    }

    @MainActor
    func testArtistScopeCannotRecolourTheBackingScreenOrPlaybackChrome() async throws {
        let settings = AppSettings()
        let previousTheme = settings.theme
        let previousCustom = settings.stored.customThemeId
        settings.useCustomTheme(nil)
        settings.theme = .artwork
        defer { settings.theme = previousTheme; settings.useCustomTheme(previousCustom) }

        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try XCTUnwrap(image.pngData()).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        let artist = AppPalette.artwork(await LyricsPaletteCache.shared.palette(for: .image(photo)))
        let red = AppPalette.artwork(.from(hue: 0, saturation: 0.8, artworkLightness: 0.3))
        let blue = AppPalette.artwork(.from(hue: 240, saturation: 0.8, artworkLightness: 0.3))
        let state = State(playback: red)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        window.rootViewController = UIHostingController(rootView: Harness(state: state, photo: photo)
            .environment(settings).environment(\.colorScheme, .dark))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        try await waitFor { state.backgroundSnapshots.last?.page == red }
        state.artistVisible = true
        try await waitFor { state.artistSnapshots.last == Snapshot(page: artist, playback: red) }
        XCTAssertEqual(state.backgroundSnapshots.last?.page, red)
        // A song change while the artist page is open updates the backing UI and chrome only.
        state.playback = blue
        try await waitFor {
            state.backgroundSnapshots.last?.page == blue && state.artistSnapshots.last == Snapshot(page: artist, playback: blue)
        }
        state.artistVisible = false
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.backgroundSnapshots.last?.page, blue)
        XCTAssertTrue(state.backgroundSnapshots.allSatisfy { $0.page == red || $0.page == blue })
    }
}
