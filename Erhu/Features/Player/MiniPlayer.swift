import SwiftUI

/// The bar above the navigation while something is loaded: artwork, title, artist, previous,
/// play / pause, next, and a thin progress line. Tapping it opens Now Playing.
struct MiniPlayer: View {
    let song: Song
    var compactness: CGFloat = 0
    let onOpen: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let state = player.state
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.md) {
                    SongArtworkView(song: song, maxPixels: 132)
                        .frame(width: ArtworkSize.miniPlayer, height: ArtworkSize.miniPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .playerArtworkFrame(expanded: false)
                        .modifier(MiniArtworkVisibility())
                        .accessibilityLabel("Album artwork")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(1)
                        Text(loadingText ?? song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")
            // Playback controls keep their left-to-right order in right-to-left languages, as on iOS.
            HStack(spacing: 4) {
                Button { player.skipPrevious() } label: { Image(systemName: "backward.fill").frame(width: 44, height: 48).contentShape(Rectangle()) }
                    .frame(width: 44 * (1 - compactness)).clipped()
                    .opacity(Double(CGFloat(1) - compactness))
                    .allowsHitTesting(compactness < 0.5)
                    .accessibilityHidden(compactness >= 0.5)
                    .accessibilityLabel("Previous track")
                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.isLoading {
                            LoadingRing(fraction: StreamLoading.shared.fraction(of: song), size: 24)
                        } else {
                            Image(systemName: player.showsPause ? "pause.fill" : "play.fill").font(.title2)
                        }
                    }
                    .frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .accessibilityLabel(player.isLoading ? "Loading, tap to stop" : (state.isPlaying ? "Pause" : "Play"))
                Button { player.skipNext() } label: { Image(systemName: "forward.fill").frame(width: 44, height: 48).contentShape(Rectangle()) }
                    .frame(width: 44 * (1 - compactness)).clipped()
                    .opacity(Double(CGFloat(1) - compactness))
                    .allowsHitTesting(compactness < 0.5)
                    .accessibilityHidden(compactness >= 0.5)
                    .accessibilityLabel("Next track")
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .foregroundStyle(palette.onSurface)
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs + 2)
        // The whole bar takes touches, so nothing behind it can be pressed through its gaps.
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            ProgressLine(durationMs: state.durationMs)
                .frame(height: 3)
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, Spacing.md)
        }
    }
}

extension MiniPlayer {
    /// "Loading 45%" while a streamed song is fetched before it plays.
    fileprivate var loadingText: String? {
        guard player.isLoading, song.isStream else { return nil }
        if let fraction = StreamLoading.shared.fraction(of: song) {
            return String(localized: "Loading \(Int(fraction * 100))%")
        }
        return String(localized: "Loading…")
    }
}

/// A spinner while a song gets ready; with a known size it fills up as the song arrives.
struct LoadingRing: View {
    let fraction: Double?
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3
    var color: Color?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle().stroke((color ?? palette.onSurface).opacity(0.25), lineWidth: lineWidth)
                    Circle().trim(from: 0, to: max(fraction, 0.03))
                        .stroke(color ?? palette.onSurface, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                }
            } else {
                ProgressView().tint(color ?? palette.onSurface)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The mini player's progress, on its own so only it redraws as the song plays.
private struct ProgressLine: View {
    let durationMs: Int64
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let progress = durationMs > 0 ? min(Double(player.clock.positionMs) / Double(durationMs), 1) : 0
        GeometryReader { geometry in
            Capsule().fill(palette.primary).frame(width: geometry.size.width * progress, height: 3)
        }
    }
}
