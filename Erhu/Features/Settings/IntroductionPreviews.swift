import AVFoundation
import SwiftUI
import UIKit

struct IntroductionPreview {
    let label: LocalizedStringKey
    let image: String
    let video: String?
    let aspectRatio: CGFloat

    init(_ label: LocalizedStringKey, image: String, video: String? = nil, aspectRatio: CGFloat = 0.49) {
        self.label = label
        self.image = image
        self.video = video
        self.aspectRatio = aspectRatio
    }
}

struct IntroductionPreviewView: View {
    let preview: IntroductionPreview
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palette) private var palette

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: Radius.large)
        VStack(spacing: Spacing.sm) {
            palette.surfaceVariant
                .aspectRatio(preview.aspectRatio, contentMode: .fit)
                .overlay {
                    if let still = UIImage(named: preview.image) {
                        Image(uiImage: still).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .overlay {
                    if isActive, !reduceMotion, scenePhase == .active,
                       let name = preview.video,
                       let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
                        IntroductionLoopingVideo(url: url).id(url)
                    }
                }
                .clipShape(frame)
                .overlay(frame.strokeBorder(palette.onSurface.opacity(0.12)))
                .accessibilityHidden(true)
            Text(preview.label)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

struct IntroductionToolsCarousel: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Int? = 0

    private let slides: [(preview: IntroductionPreview, caption: LocalizedStringKey)] = [
        (IntroductionPreview("Covers and artist photos", image: "OnboardingArtworkFetcher"),
         "Find album covers and artist photos, then review and apply your choices."),
        (IntroductionPreview("Fix tags", image: "OnboardingFixTags"),
         "Repair incomplete tags and review matches before updating your music files."),
        (IntroductionPreview("Library Builder", image: "OnboardingLibraryBuilder"),
         "Organize your music into folders using its tags. Review proposed moves before applying them.")
    ]

    var body: some View {
        let current = selection ?? 0
        VStack(spacing: Spacing.sm) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(slides.indices, id: \.self) { index in
                        IntroductionPreviewView(preview: slides[index].preview)
                            .frame(maxWidth: 150)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selection)
            .scrollIndicators(.hidden)

            Text(slides[current].caption)
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                ForEach(slides.indices, id: \.self) { index in
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = index }
                    } label: {
                        Circle()
                            .fill(index == current ? palette.primary : palette.onSurface.opacity(0.24))
                            .frame(width: 8, height: 8)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Show preview \(index + 1) of \(slides.count)"))
                    .accessibilityAddTraits(index == current ? .isSelected : [])
                }
            }
        }
    }
}

private struct IntroductionLoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.isOpaque = false
        view.start(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private let player = AVQueuePlayer(items: [])
        private var looper: AVPlayerLooper?
        private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        func start(url: URL) {
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer?.videoGravity = .resizeAspect
            playerLayer?.player = player
            player.play()
        }

        func stop() {
            player.pause()
            playerLayer?.player = nil
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }
    }
}
