import AVKit
import SwiftUI

struct MotionCompressionPreviewView: View {
    let preview: MotionCompressionPreview
    @Environment(AnimatedArtworkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var original: AVPlayer
    @State private var compressed: AVPlayer
    init(preview: MotionCompressionPreview) {
        self.preview = preview
        _original = State(initialValue: AVPlayer(url: preview.original))
        _compressed = State(initialValue: AVPlayer(url: preview.candidate))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(preview.title).font(.title2.bold())
                    Text("Compression is lossy. Compare detail, dark areas and motion before choosing. The original remains saved until you use the compressed cover.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Original · " + ByteCountFormatter.string(fromByteCount: preview.originalBytes, countStyle: .file)).font(.headline)
                    VideoPlayer(player: original).aspectRatio(1, contentMode: .fit)
                    Text("Compressed · " + ByteCountFormatter.string(fromByteCount: preview.candidateBytes, countStyle: .file)).font(.headline)
                    VideoPlayer(player: compressed).aspectRatio(1, contentMode: .fit)
                    Text("Saves " + ByteCountFormatter.string(fromByteCount: preview.saving, countStyle: .file))
                    if let message = store.compressionMessage { Text(message).font(.footnote) }
                    Button("Use compressed cover") {
                        store.acceptCompression()
                        if store.compressionPreview == nil { dismiss() }
                    }.buttonStyle(.borderedProminent)
                    Button("Keep original") { store.discardCompression(); dismiss() }.buttonStyle(.bordered)
                }.padding(Spacing.lg)
            }.navigationTitle("Compare covers").navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { original.isMuted = true; compressed.isMuted = true; original.play(); compressed.play() }
        .onDisappear { original.pause(); compressed.pause() }
    }
}
