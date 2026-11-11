import AppIntents
import SwiftUI
import WidgetKit

/// The playing song on the Home Screen, in two sizes: a wide, short one (cover, song, progress and
/// controls) and a wide, tall one that adds a large cover and what plays next.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing and control playback.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    /// The App Group is missing (the app was installed without it), so nothing can be shown.
    var unavailable = false

    static let sample = NowPlayingEntry(date: Date(), snapshot: NowPlayingSnapshot(
        title: "Song title", artist: "Artist", album: "Album", isPlaying: true, positionMs: 72_000, durationMs: 214_000,
        capturedAt: Date(), artworkFile: nil,
        upNext: [.init(title: "Next song", artist: "Artist"), .init(title: "Another song", artist: "Artist"),
                 .init(title: "One more song", artist: "Artist")]))
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let snapshot = WidgetShared.load()
        completion(context.isPreview && snapshot == nil ? .sample : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = current()
        // The app asks for a redraw whenever playback changes. A playing song is redrawn once more
        // when it should have ended, in case the app could not say what came next.
        if let snapshot = entry.snapshot, snapshot.isPlaying {
            completion(Timeline(entries: [entry], policy: .after(snapshot.endDate.addingTimeInterval(2))))
        } else {
            completion(Timeline(entries: [entry], policy: .never))
        }
    }

    private func current() -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: WidgetShared.load(), unavailable: WidgetShared.containerURL == nil)
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemLarge: LargeNowPlaying(snapshot: snapshot, artwork: artwork(snapshot))
                default: MediumNowPlaying(snapshot: snapshot, artwork: artwork(snapshot))
                }
            } else {
                EmptyNowPlaying(unavailable: entry.unavailable)
            }
        }
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) { WidgetBackdrop(artwork: entry.snapshot.flatMap(artwork)) }
    }

    private func artwork(_ snapshot: NowPlayingSnapshot) -> UIImage? {
        WidgetShared.artworkURL(snapshot).flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

/// The cover, blurred and darkened behind everything (a deep neutral when there is no cover).
private struct WidgetBackdrop: View {
    let artwork: UIImage?

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.10, blue: 0.10)
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill().blur(radius: 28).scaleEffect(1.3)
                    .opacity(0.9)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct CoverView: View {
    let artwork: UIImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: side * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

/// Song title and artist; the album as well where there is room.
private struct SongTitles: View {
    let snapshot: NowPlayingSnapshot
    var titleFont: Font = .headline
    var showsAlbum = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title).font(titleFont).foregroundStyle(.white).lineLimit(2)
            Text(snapshot.artist).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            if showsAlbum, !snapshot.album.isEmpty {
                Text(snapshot.album).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin bar that moves on by itself while playing.
private struct SongProgress: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        Group {
            if snapshot.isPlaying, snapshot.durationMs > 0, snapshot.endDate > Date() {
                ProgressView(timerInterval: snapshot.startDate...snapshot.endDate, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: Double(snapshot.positionMs), total: Double(max(snapshot.durationMs, 1)))
            }
        }
        .progressViewStyle(.linear)
        .labelsHidden()
        .tint(.white)
        // A timeline runs left to right in every language, like the player's.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Previous, play / pause, next. These run in the app, which keeps playing in the background.
private struct PlaybackButtons: View {
    let isPlaying: Bool
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill").font(.system(size: size, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel(Text("Previous"))
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 1.25, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill").font(.system(size: size, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel(Text("Next"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        // Playback controls keep their left-to-right order in every language, as on iOS.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The wide, short widget: the cover on one side, the song, progress and controls beside it.
private struct MediumNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let artwork: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.height - 32
            HStack(spacing: 14) {
                CoverView(artwork: artwork, side: side, radius: 12)
                VStack(alignment: .leading, spacing: 6) {
                    SongTitles(snapshot: snapshot)
                    Spacer(minLength: 0)
                    SongProgress(snapshot: snapshot)
                    PlaybackButtons(isPlaying: snapshot.isPlaying)
                }
            }
            .padding(16)
        }
    }
}

/// The wide, tall widget: a large cover and the song, progress, controls, then what plays next.
private struct LargeNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let artwork: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CoverView(artwork: artwork, side: 116, radius: 14)
                VStack(alignment: .leading, spacing: 0) {
                    SongTitles(snapshot: snapshot, titleFont: .title3.weight(.bold), showsAlbum: true)
                    Spacer(minLength: 0)
                }
                .frame(height: 116)
            }
            SongProgress(snapshot: snapshot)
            PlaybackButtons(isPlaying: snapshot.isPlaying, size: 24)
            UpNextList(tracks: snapshot.upNext)
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

private struct UpNextList: View {
    let tracks: [NowPlayingSnapshot.Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).textCase(.uppercase)
            if tracks.isEmpty {
                Text("Nothing else in the queue").font(.footnote).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(tracks.prefix(3).enumerated()), id: \.offset) { _, track in
                HStack(spacing: 8) {
                    Text(track.title).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(track.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyNowPlaying: View {
    let unavailable: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12))
                Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing").font(.headline).foregroundStyle(.white)
                (unavailable ? Text("Reinstall Erhu with your installer to use this widget.") : Text("Open Erhu to play music."))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
