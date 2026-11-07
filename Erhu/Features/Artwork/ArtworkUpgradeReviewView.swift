import SwiftUI

/// Both images stay visible in one review, using the exact bytes the Apply action will save.
struct ArtworkUpgradeReviewView: View {
    let review: ArtworkUpgradeReview
    let saving: Bool
    let error: String?
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(review.upgrade.target.name).font(.headline)
                    comparisonImage(review.original, label: "Current", facts: review.originalFacts)
                    comparisonImage(review.replacement, label: "Replacement", facts: review.replacementFacts)
                    Text(review.upgrade.candidate.source).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                    if let credit = review.upgrade.candidate.credit {
                        Text(credit.author + " · " + credit.license).font(.caption)
                        Link("Image source", destination: credit.page)
                    }
                    Text("Confirm this is the same image before replacing it. Other tags stay unchanged. Saved artwork fits within \(TagWriter.maxArtworkPixels) pixels.")
                        .font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("artwork-upgrade-error") }
                }
                .padding(Spacing.lg)
            }
            .background(palette.background)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Spacing.sm) {
                    Button(action: apply) {
                        HStack {
                            if saving { ProgressView().tint(palette.onFilledButton) }
                            Text(saving ? "Saving…" : "Use higher-resolution image")
                        }
                        .frame(maxWidth: .infinity).foregroundStyle(palette.onFilledButton)
                    }
                    .modifier(PaletteFilledButton()).tint(palette.filledButton)
                    .accessibilityIdentifier("artwork-upgrade-apply")
                    Button("Keep current") { dismiss() }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("artwork-upgrade-keep-current")
                }
                .controlSize(.large).disabled(saving)
                .padding(Spacing.lg).background(.regularMaterial)
            }
            .navigationTitle("Review artwork upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func comparisonImage(_ data: Data, label: String, facts: ArtworkImageFacts) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("\(label) · \(facts.resolution)").font(.subheadline.weight(.semibold))
            if let image = ArtworkImageFacts.thumbnail(data, maxPixels: 1600) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(label) artwork, \(facts.width) by \(facts.height) pixels")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
