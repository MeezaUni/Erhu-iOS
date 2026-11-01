import SwiftUI
import UIKit
import XCTest
@testable import Erhu

final class ToolPageAppearanceTests: XCTestCase {
    private struct Probe: View {
        let record: (AppPalette) -> Void
        @Environment(\.palette) private var palette
        var body: some View {
            Color.clear.frame(height: 30)
                .onChange(of: palette, initial: true) { _, value in record(value) }
        }
    }

    @MainActor
    func testMenuAndSettingsAppearancePreserveArtworkAndImportedThemePalettes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let custom = AppPalette(primary: .green, onPrimary: .black, background: .purple, surface: .blue,
                                surfaceVariant: .cyan, onSurface: .white, onSurfaceVariant: .gray, outline: .orange)
        let choices: [(AppPalette, ColorScheme)] = [
            (.artwork(.from(hue: 210, saturation: 0.8, artworkLightness: 0.3)), .dark),
            (.artwork(.from(hue: 340, saturation: 0.8, artworkLightness: 0.3), scheme: .light), .light),
            (custom, .dark),
        ]
        for (palette, scheme) in choices {
            var menu: AppPalette?, settings: AppPalette?
            let root = VStack {
                Probe { menu = $0 }.modifier(ToolPageAppearance())
                Probe { settings = $0 }.modifier(ToolPageAppearance()).modifier(ToolPageAppearance())
            }.environment(\.palette, palette).environment(\.colorScheme, scheme)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            for _ in 0..<150 {
                if menu != nil && settings != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(menu, palette)
            XCTAssertEqual(settings, palette, "Settings must keep the same active theme as the menu")
        }
    }
}
