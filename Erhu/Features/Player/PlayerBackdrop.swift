import CoreImage
import SwiftUI
import UIKit

/// What sits behind Now Playing (Settings > Appearance).
enum PlayerBackdropStyle: String, CaseIterable, Codable, Identifiable {
    /// The song's colours with a faint wash of its cover (the default).
    case artworkColours
    /// The song's cover, blurred, filling the screen.
    case blurredArtwork
    var id: String { rawValue }

    var label: String {
        switch self {
        case .artworkColours: String(localized: "Cover colours")
        case .blurredArtwork: String(localized: "Blurred cover")
        }
    }
}

/// Blurred covers made once per song at a small size and kept, so the Now Playing background is
/// a plain picture while cards move and the player is pulled down; a live full-screen blur
/// redrew on every frame of those motions. Usable from any thread.
enum BlurredArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()
    private static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    /// Small on purpose: blurred, it is scaled up to the screen without any visible loss.
    private static let pixels = 96

    private static func key(_ url: URL) -> NSString {
        "\(url.path)|\(ArtworkLoader.shared.revision(for: url.path))" as NSString
    }

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: key(url)) }

    /// The blurred cover of the song at [url] (nil when it has no cover).
    static func image(for url: URL) async -> UIImage? {
        let key = key(url)
        if let done = cache.object(forKey: key) { return done }
        guard let cover = await ArtworkLoader.shared.image(for: url, maxPixels: pixels) else { return nil }
        let blurred = await Task.detached(priority: .utility) { blur(cover) }.value
        if let blurred { cache.setObject(blurred, forKey: key) }
        return blurred
    }

    private static func blur(_ image: UIImage) -> UIImage? {
        guard let input = image.cgImage.map({ CIImage(cgImage: $0) }) else { return nil }
        let extent = input.extent
        // Clamped first, so the edges don't fade to transparent.
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.08])
            .cropped(to: extent)
        guard let cg = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Now Playing's background. The picture changes once a skip has settled, cross-fading from the
/// previous one (kept until the new one is ready), and the neighbouring songs' pictures are made
/// ahead so a skip never waits for one.
struct PlayerBackdrop: View {
    let song: Song?
    var upcoming: [URL] = []
    let style: PlayerBackdropStyle
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme
    @State private var shown: UIImage?
    @State private var shownURL: URL?

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.surface, palette.background], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(style == .blurredArtwork ? 1.15 : 1.5)
                    .opacity(style == .blurredArtwork ? 1 : 0.14)
                    .id(ObjectIdentifier(shown))
                    .transition(.opacity)
                if style == .blurredArtwork {
                    // Keeps text readable over any cover.
                    palette.background.opacity(scheme == .dark ? 0.42 : 0.3)
                }
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: shown.map(ObjectIdentifier.init))
        .task(id: song?.url) {
            guard let url = song?.url else { shown = nil; shownURL = nil; return }
            if shownURL == nil, let ready = BlurredArtwork.cached(url) {
                shown = ready; shownURL = url
            } else {
                let made = await BlurredArtwork.image(for: url)
                guard !Task.isCancelled else { return }
                // Wait for a skip's card motion to settle before the background changes.
                if shownURL != nil { try? await Task.sleep(for: .seconds(CarouselSettlementTiming.trackSettleDuration)) }
                guard !Task.isCancelled else { return }
                shown = made; shownURL = url
            }
            for next in upcoming where next != url {
                guard !Task.isCancelled else { return }
                _ = await BlurredArtwork.image(for: next)
            }
        }
    }
}
