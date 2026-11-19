import CoreImage
import SwiftUI
import UIKit

/// What a stats card shows (Android's StatsCardType).
enum StatsCardType: String, CaseIterable, Identifiable {
    case topSongs, topArtists, topAlbums, overview
    var id: String { rawValue }

    var label: String {
        switch self {
        case .topSongs: String(localized: "Top songs")
        case .topArtists: String(localized: "Top artists")
        case .topAlbums: String(localized: "Top albums")
        case .overview: String(localized: "Overview")
        }
    }
}

/// A stats card's shape (Android's CardAspectRatio), sized in points; saved at 3x (1080 px wide).
enum StatsCardShape: String, CaseIterable, Identifiable {
    case story, square, portrait
    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .story: CGSize(width: 360, height: 640)
        case .square: CGSize(width: 360, height: 360)
        case .portrait: CGSize(width: 360, height: 450)
        }
    }

    var label: String {
        switch self {
        case .story: String(localized: "Story")
        case .square: String(localized: "Square")
        case .portrait: String(localized: "Portrait")
        }
    }
}

/// The pictures a card draws, loaded before rendering (ImageRenderer can't wait for any).
struct StatsCardArtwork {
    var songs: [Int64: UIImage] = [:]
    var albums: [Int64: UIImage] = [:]
    var artists: [Int64: UIImage] = [:]
    /// The top item's cover, blurred, behind everything.
    var backdrop: UIImage?
    /// The black share white text needs to stay readable over [backdrop].
    var readableDarkness: Double = 0
}

/// Share stats (Android's StatsShareDialog): pick the period, what the card shows, its shape and
/// how dark it is; the preview is the very image that is saved or shared.
struct StatsShareSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var period: StatsPeriod = .thisMonth
    @State private var type: StatsCardType = .topSongs
    @State private var shape: StatsCardShape = .story
    @State private var darkness: Double = 0.4
    @State private var stats: PeriodStats?
    @State private var artwork = StatsCardArtwork()
    @State private var rendered: UIImage?
    @State private var saver = PhotoSaver()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    preview
                    choices(String(localized: "Period"), StatsPeriod.allCases, selected: $period, label: \.label)
                    choices(String(localized: "Card"), StatsCardType.allCases, selected: $type, label: \.label)
                    choices(String(localized: "Shape"), StatsCardShape.allCases, selected: $shape, label: \.label)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text("Darkness").font(.headline)
                            Spacer()
                            Text(darkness.formatted(.percent.precision(.fractionLength(0))))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
                        }
                        Slider(value: $darkness, in: 0.15...0.85)
                    }
                    .padding(.horizontal, Spacing.gutter)
                    actionsRow
                }
                .padding(.vertical, Spacing.md)
            }
            .navigationTitle("Share stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task(id: period) { await load() }
        .task(id: renderKey) { render() }
    }

    private var renderKey: String {
        "\(period.rawValue)|\(type.rawValue)|\(shape.rawValue)|\(Int(darkness * 100))|\(stats == nil)|\(artwork.songs.count)|\(artwork.albums.count)|\(artwork.artists.count)|\(artwork.backdrop != nil)"
    }

    private static let previewHeight: CGFloat = 340

    /// The card as it will be saved, at most 72% of the width and [previewHeight] tall.
    private var preview: some View {
        GeometryReader { geometry in
            let size = shape.size
            let height = Self.previewHeight
            let width = min(geometry.size.width * 0.72, height * size.width / size.height)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(palette.surfaceVariant)
                if let rendered {
                    Image(uiImage: rendered).resizable().scaledToFit()
                        .accessibilityLabel(Text("Share stats"))
                } else {
                    ProgressView()
                }
            }
            .frame(width: width, height: width * size.height / size.width)
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .frame(height: Self.previewHeight)
        .animation(.smooth(duration: 0.25), value: shape)
    }

    private func choices<T: Identifiable & Hashable>(_ title: String, _ options: [T], selected: Binding<T>,
                                                     label: KeyPath<T, String>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.headline).padding(.horizontal, Spacing.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(options) { option in
                        let on = option == selected.wrappedValue
                        Button { selected.wrappedValue = option } label: {
                            Text(option[keyPath: label]).font(.subheadline.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, Spacing.md)
                                .frame(minHeight: 36)
                                .foregroundStyle(on ? palette.onPrimary : palette.onSurface)
                                .background(Capsule().fill(on ? palette.primary : palette.onSurface.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                guard let rendered else { return }
                saver.save(rendered) { saved in
                    actions.show(saved ? String(localized: "Saved to Photos") : String(localized: "Couldn't save to Photos"))
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(Capsule().stroke(palette.onSurface.opacity(0.3)))
            }
            .buttonStyle(.plain)
            if let rendered {
                ShareLink(item: Image(uiImage: rendered), preview: SharePreview(period.label, image: Image(uiImage: rendered))) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(palette.onPrimary)
                        .background(Capsule().fill(palette.primary))
                }
                .buttonStyle(.plain)
            } else {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(palette.onPrimary.opacity(0.6))
                    .background(Capsule().fill(palette.primary.opacity(0.5)))
            }
        }
        .font(.headline)
        .disabled(rendered == nil)
        .padding(.horizontal, Spacing.gutter)
    }

    private func load() async {
        let database = library.database
        let period = period
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? database.periodStats(period)) ?? PeriodStats(period: period)
        }.value
        guard !Task.isCancelled else { return }
        stats = loaded
        artwork = await Self.artwork(for: loaded, covers: library.albumCoverSong)
    }

    private static let artworkPixels = 320

    private static func artwork(for stats: PeriodStats, covers: [Int64: Song]) async -> StatsCardArtwork {
        var art = StatsCardArtwork()
        for ranked in stats.topSongs.prefix(5) {
            art.songs[ranked.song.id] = await ArtworkLoader.shared.image(for: ranked.song.url, maxPixels: artworkPixels)
        }
        for ranked in stats.topAlbums.prefix(5) {
            if let url = covers[ranked.album.id]?.url {
                art.albums[ranked.album.id] = await ArtworkLoader.shared.image(for: url, maxPixels: artworkPixels)
            }
        }
        for ranked in stats.topArtists.prefix(5) {
            if let path = ranked.artist.artworkPath {
                art.artists[ranked.artist.id] = await ArtworkLoader.shared.image(atPath: LibraryPaths.resolveImage(path), maxPixels: artworkPixels)
            }
        }
        // Behind the card: the top song's cover, else the top album's, else the top artist's.
        let source = stats.topSongs.first.flatMap { art.songs[$0.song.id] }
            ?? stats.topAlbums.first.flatMap { art.albums[$0.album.id] }
            ?? stats.topArtists.first.flatMap { art.artists[$0.artist.id] }
        if let source {
            let made = await Task.detached(priority: .userInitiated) { StatsCardBackdrop.make(source) }.value
            art.backdrop = made?.image
            art.readableDarkness = made?.readableDarkness ?? 0
        }
        return art
    }

    private func render() {
        guard let stats else { rendered = nil; return }
        let card = StatsCard(stats: stats, type: type, shape: shape, darkness: darkness, artwork: artwork)
            .environment(\.layoutDirection, .leftToRight)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(shape.size)
        rendered = renderer.uiImage
    }
}

/// Saves a card to the photo library (asks for add-only access the first time).
@MainActor
final class PhotoSaver: NSObject {
    private var done: ((Bool) -> Void)?

    func save(_ image: UIImage, done: @escaping (Bool) -> Void) {
        self.done = done
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(finished(_:error:context:)), nil)
    }

    @objc private func finished(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        done?(error == nil)
        done = nil
    }
}

/// The blurred backdrop and how dark it must be for white text (about 4.5:1 contrast).
enum StatsCardBackdrop {
    static func make(_ image: UIImage) -> (image: UIImage, readableDarkness: Double)? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.06])
            .cropped(to: extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let out = context.createCGImage(blurred, from: extent) else { return nil }
        return (UIImage(cgImage: out), readableDarkness(out))
    }

    /// White on luminance L' has (1.05) / (L' + 0.05) contrast; L' = L * (1 - d).
    static func readableDarkness(_ image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
        }
        let luminance = total / Double(side * side)
        let target = 1.05 / 4.5 - 0.05
        return luminance <= target ? 0 : min(max(1 - target / luminance, 0), 0.9)
    }
}

/// The stats card itself (Android's StatsCardRenderer): Story stacks one column; Portrait and
/// Square put top songs and albums side by side in the overview, and Square moves the totals
/// beside the title. White on the blurred top cover, "E R H U" at the foot.
struct StatsCard: View {
    let stats: PeriodStats
    let type: StatsCardType
    let shape: StatsCardShape
    let darkness: Double
    let artwork: StatsCardArtwork

    private static let margin: CGFloat = 27
    private static let top = 5

    private var insets: (top: CGFloat, bottom: CGFloat) {
        switch shape {
        case .story: (56, 50)
        case .portrait: (32, 31)
        case .square: (25, 27)
        }
    }

    var body: some View {
        let size = shape.size
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Text(verbatim: "E R H U").font(.system(size: 7.5, weight: .bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.63))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .foregroundStyle(.white)
    }

    private var background: some View {
        let dark = max(darkness.clamped(0.1, 0.9), artwork.readableDarkness)
        return ZStack {
            if let backdrop = artwork.backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
                    .frame(width: shape.size.width, height: shape.size.height).clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.094, green: 0.102, blue: 0.125), Color(red: 0.031, green: 0.035, blue: 0.047)],
                               startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.black.opacity(dark), .black.opacity(min(1, dark + 0.24))], startPoint: .top, endPoint: .bottom)
        }
    }

    private var isEmpty: Bool {
        switch type {
        case .overview: stats.isEmpty
        case .topSongs: stats.topSongs.isEmpty
        case .topArtists: stats.topArtists.isEmpty
        case .topAlbums: stats.topAlbums.isEmpty
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            empty
        } else if type == .overview {
            overview
        } else {
            ranking
        }
    }

    private func header(_ eyebrow: String, scale k: CGFloat = 1) -> some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            Text(eyebrow.uppercased(with: .current)).font(.system(size: 9.5 * k, weight: .bold)).tracking(1.5 * k)
                .foregroundStyle(.white.opacity(0.75))
            Text(stats.period.label).font(.system(size: 21 * k, weight: .bold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased(with: .current)).font(.system(size: 8.5, weight: .bold)).tracking(1.2)
            .foregroundStyle(.white.opacity(0.78)).lineLimit(1)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(type == .overview ? String(localized: "Sound Capsule") : type.label)
            Spacer()
            VStack(spacing: Spacing.sm) {
                Image(systemName: "music.note").font(.system(size: 22, weight: .bold))
                    .frame(width: 42, height: 42).background(Circle().fill(.white.opacity(0.16)))
                Text("No listening yet").font(.system(size: 14, weight: .bold))
                Text("Play some music and your recap will show up here.").font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.67)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: Single rankings

    private struct Row: Identifiable {
        let id: Int64
        let title: String
        let subtitle: String?
        let plays: Int
        let image: UIImage?
        let round: Bool
    }

    private var rows: [Row] {
        switch type {
        case .topSongs:
            stats.topSongs.prefix(Self.top).map { Row(id: $0.song.id, title: $0.song.title, subtitle: $0.song.artist, plays: $0.plays,
                                                     image: artwork.songs[$0.song.id], round: false) }
        case .topAlbums:
            stats.topAlbums.prefix(Self.top).map { Row(id: $0.album.id, title: $0.album.title, subtitle: $0.album.artist, plays: $0.plays,
                                                      image: artwork.albums[$0.album.id], round: false) }
        default:
            stats.topArtists.prefix(Self.top).map { Row(id: $0.artist.id, title: $0.artist.name, subtitle: nil, plays: $0.plays,
                                                       image: artwork.artists[$0.artist.id], round: true) }
        }
    }

    /// Five equal row slots (fewer results keep the same size), centred under the header.
    private var ranking: some View {
        let available = shape.size.height - insets.top - insets.bottom - 24
        let k: CGFloat = shape == .story ? 1.1 : shape == .portrait ? 1 : 0.88
        let headerHeight = 40 * k + 18
        let rowHeight = min((available - headerHeight) / CGFloat(Self.top), (shape.size.width - 2 * Self.margin) * 0.24)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            header(type.label, scale: k).padding(.bottom, 18)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rankedRow(index + 1, row, height: rowHeight, narrow: false)
            }
            ForEach(rows.count..<Self.top, id: \.self) { _ in Color.clear.frame(height: rowHeight) }
            Spacer(minLength: 0)
        }
    }

    /// Rank, artwork, title over subtitle, plays at the end (under the title when narrow).
    private func rankedRow(_ rank: Int, _ row: Row, height: CGFloat, narrow: Bool) -> some View {
        let titleSize = (height * 0.26).clamped(9, 15.5)
        let thumb = height * 0.74
        return HStack(spacing: 0) {
            Text(StatsText.number(Int64(rank))).font(.system(size: titleSize * 1.05, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: titleSize * 1.2)
                .padding(.trailing, titleSize * 0.35)
            art(row.image, round: row.round, name: row.title).frame(width: thumb, height: thumb)
                .padding(.trailing, height * 0.2)
            VStack(alignment: .leading, spacing: titleSize * 0.18) {
                Text(row.title).font(.system(size: titleSize, weight: .bold)).lineLimit(1)
                if let subtitle = row.subtitle {
                    HStack(spacing: 4) {
                        Text(subtitle).font(.system(size: titleSize * 0.8)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                        if narrow {
                            Spacer(minLength: 2)
                            Text(StatsText.plays(row.plays)).font(.system(size: titleSize * 0.8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.67)).lineLimit(1).layoutPriority(1)
                        }
                    }
                }
            }
            Spacer(minLength: titleSize * 0.6)
            if !narrow || row.subtitle == nil {
                Text(StatsText.plays(row.plays)).font(.system(size: titleSize * 0.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.67)).lineLimit(1).layoutPriority(1)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func art(_ image: UIImage?, round: Bool, name: String) -> some View {
        if let image {
            if round {
                Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                GeometryReader { g in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: g.size.width * 0.12, style: .continuous))
                }
            }
        } else if round {
            Circle().fill(.white.opacity(0.18))
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 14, weight: .bold)))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(red: 0.18, green: 0.22, blue: 0.28).opacity(0.7))
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)))
        }
    }

    // MARK: Overview

    private var overview: some View {
        let songs = Array(stats.topSongs.prefix(Self.top))
        let albums = Array(stats.topAlbums.prefix(Self.top))
        let artists = Array(stats.topArtists.prefix(Self.top))
        let gap: CGFloat = shape == .story ? 20 : 12
        return VStack(alignment: .leading, spacing: gap) {
            if shape == .square {
                HStack(alignment: .center, spacing: 11) {
                    header(String(localized: "Sound Capsule"), scale: 0.85)
                    Spacer(minLength: 0)
                    totals(scale: 0.8).frame(width: (shape.size.width - 2 * Self.margin) * 0.54)
                }
            } else {
                header(String(localized: "Sound Capsule"))
                totals(scale: 1)
            }
            if !artists.isEmpty && shape != .square { artistsRow(artists) }
            if shape == .story {
                if !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        heading(String(localized: "Top songs"))
                        ForEach(Array(songs.enumerated()), id: \.element.song.id) { index, ranked in
                            rankedRow(index + 1, Row(id: ranked.song.id, title: ranked.song.title, subtitle: ranked.song.artist,
                                                     plays: ranked.plays, image: artwork.songs[ranked.song.id], round: false),
                                      height: 38, narrow: false)
                        }
                    }
                }
                if !albums.isEmpty { albumTiles(albums) }
            } else {
                let rowHeight: CGFloat = shape == .square ? 36 : 37
                HStack(alignment: .top, spacing: 13) {
                    column(String(localized: "Top songs"), songs.map { ranked in
                        Row(id: ranked.song.id, title: ranked.song.title, subtitle: ranked.song.artist, plays: ranked.plays,
                            image: artwork.songs[ranked.song.id], round: false)
                    }, rowHeight: rowHeight)
                    column(String(localized: "Top albums"), albums.map { ranked in
                        Row(id: ranked.album.id, title: ranked.album.title, subtitle: ranked.album.artist, plays: ranked.plays,
                            image: artwork.albums[ranked.album.id], round: false)
                    }, rowHeight: rowHeight)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func column(_ title: String, _ rows: [Row], rowHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !rows.isEmpty {
                heading(title)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rankedRow(index + 1, row, height: rowHeight, narrow: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Minutes listened, plays and tracks in three equal columns.
    private func totals(scale k: CGFloat) -> some View {
        let items: [(String, String)] = [
            (StatsText.number(stats.listenedMs / 60_000), String(localized: "Minutes listened")),
            (StatsText.number(Int64(stats.totalPlays)), StatsText.playsUnit(stats.totalPlays)),
            (StatsText.number(Int64(stats.uniqueTracks)), StatsText.tracksUnit(stats.uniqueTracks)),
        ]
        return HStack(alignment: .top, spacing: 5) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(items[i].0).font(.system(size: 18.5 * k, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(items[i].1.uppercased(with: .current)).font(.system(size: 7.3 * k, weight: .bold)).tracking(0.7 * k)
                        .foregroundStyle(.white.opacity(0.69)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Up to five artists in equal slots: round photo with its rank, name underneath.
    private func artistsRow(_ artists: [RankedArtist]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            heading(String(localized: "Top artists"))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.element.artist.id) { index, ranked in
                    VStack(spacing: 5) {
                        art(artwork.artists[ranked.artist.id], round: true, name: ranked.artist.name)
                            .frame(width: shape == .story ? 44 : 38, height: shape == .story ? 44 : 38)
                            .overlay(alignment: .topLeading) { badge(index + 1, size: 13) }
                        Text(ranked.artist.name).font(.system(size: 8.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(artists.count..<Self.top, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    private func albumTiles(_ albums: [RankedAlbum]) -> some View {
        let tile = (shape.size.width - 2 * Self.margin - 4 * 7) / 5
        return VStack(alignment: .leading, spacing: 8) {
            heading(String(localized: "Top albums"))
            HStack(alignment: .top, spacing: 7) {
                ForEach(Array(albums.enumerated()), id: \.element.album.id) { index, ranked in
                    VStack(alignment: .leading, spacing: 1) {
                        art(artwork.albums[ranked.album.id], round: false, name: ranked.album.title)
                            .frame(width: tile, height: tile)
                            .overlay(alignment: .topLeading) { badge(index + 1, size: 12) }
                            .padding(.bottom, 4)
                        Text(ranked.album.title).font(.system(size: 8.5, weight: .bold)).lineLimit(1)
                        Text(ranked.album.artist).font(.system(size: 7.3)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                        Text(StatsText.plays(ranked.plays)).font(.system(size: 7.3, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    .frame(width: tile, alignment: .leading)
                }
            }
        }
    }

    private func badge(_ rank: Int, size: CGFloat) -> some View {
        Text(StatsText.number(Int64(rank))).font(.system(size: size * 0.52, weight: .bold))
            .frame(width: size, height: size)
            .background(Circle().fill(.black.opacity(0.82)))
            .offset(x: size * 0.12, y: size * 0.12)
    }
}
