import SwiftUI

/// A full-width collection image fading into the page, with the title over its lower edge.
/// The artwork fills a rectangular canvas; it is never inset in a square or circle.
struct CollectionHeroHeader<Cover: View>: View {
    let title: String
    let subtitle: String?
    let facts: String
    let canPlay: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let cover: () -> Cover
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            CollectionHeroLayout() {
                cover()
                    .accessibilityHidden(true)
                VStack(spacing: Spacing.sm) {
                    Text(title).font(.largeTitle.weight(.bold)).lineLimit(3)
                    if let subtitle { Text(subtitle).font(.title3.weight(.semibold)) }
                    Text(facts).font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.onSurface)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .padding(.horizontal, Spacing.heroGutter)
                .padding(.bottom, Spacing.lg)
                .frame(maxWidth: .infinity)
                // Keep the image visible behind the title. The fade starts just above it
                // and only reaches the page colour at the bottom of the metadata.
                .background {
                    GeometryReader { geometry in
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: palette.background.opacity(0.18), location: 0.3),
                            .init(color: palette.background.opacity(0.75), location: 0.75),
                            .init(color: palette.background, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        .frame(height: geometry.size.height + 48)
                        .offset(y: -48)
                    }
                }
            }
            .clipped()
            HStack(spacing: Spacing.md) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).foregroundStyle(palette.onPrimary)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onShuffle) {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.headline)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(!canPlay)
            .padding(.horizontal, Spacing.heroGutter)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Measure the metadata too, so large text and long titles can grow the header without clipping.
struct CollectionHeroLayout: Layout {
    static func height(width: CGFloat, metadataHeight: CGFloat) -> CGFloat {
        max((width * 1.08).clamped(320, 560), metadataHeight + 160)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(proposal.width ?? 390, 1)
        let metadata = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: Self.height(width: width, metadataHeight: metadata.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

struct CollectionPageBackground: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.background.ignoresSafeArea() }
}

/// Preserve crisp artwork behind the navigation controls rather than the system's top haze.
struct CollectionTopEdgeEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
