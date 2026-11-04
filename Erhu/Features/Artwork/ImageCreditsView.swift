import SwiftUI

struct ImageCreditsView: View {
    @State private var credits = ArtworkCredits.shared
    var body: some View {
        List {
            Section {
                Text("Creator and licence information for Commons images selected in Erhu. Images may be displayed resized or cropped. Follow the source licence if you share an image elsewhere.")
                    .font(.footnote).foregroundStyle(.secondary)
                if credits.records.isEmpty { Text("No Commons images have been saved yet.").foregroundStyle(.secondary) }
            }
            ForEach(credits.records.values.sorted { $0.title < $1.title }) { credit in
                Section {
                    Text(credit.title).font(.headline)
                    Text(credit.author).font(.subheadline)
                    Text(credit.license).font(.caption)
                    Link("Original image & creator", destination: credit.page)
                    if let url = credit.licenseURL { Link("Licence", destination: url) }
                }
            }
        }.navigationTitle("Image credits").modifier(ToolPageAppearance())
    }
}
