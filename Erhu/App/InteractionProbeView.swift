#if DEBUG
import SwiftUI

/// Native automation exercises production controls without a music import or network request.
struct InteractionProbeView: View {
    let page: String
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var showsSearch = false
    @State private var chrome = LibraryChromeState()

    var body: some View {
        @Bindable var router = router
        Group {
            if page == "search" {
                Button("Open search") { router.showsSearch = true }
                    .accessibilityIdentifier("openSearchProbe")
                    .sheet(isPresented: $router.showsSearch) { SearchView() }
            } else if page == "browse" {
                NavigationStack {
                    LibraryBrowseScrollView(title: "Albums", query: $query, showsSearch: $showsSearch) {
                        Text("Sort by title").accessibilityIdentifier("sortProbe")
                    } content: {
                        LazyVStack { ForEach(0..<100) { Text("Album \($0)").frame(height: 60) } }
                    }
                }.environment(chrome).environment(\.artworkSection, router.section)
            } else if page == "tools" {
                NavigationStack {
                    ToolView(tool: .autoFixTags).tracksLibraryScrolling(usesUIKit: true)
                        .overlay(alignment: .bottom) {
                            Text(String(format: "%.2f", Double(chrome.fraction))).accessibilityIdentifier("chromeFraction")
                        }
                }.environment(chrome).environment(\.artworkSection, router.section)
            } else if page == "animated-covers" {
                #if ERHU_ANIMATED_ART
                NavigationStack { AnimatedArtworkView() }
                #endif
            } else if page == "carousel" {
                ScrollView {
                    SmartMixHero(mixes: [MixKind.chill, .lateNight, .throwbacks].map {
                        SmartMix(kind: $0, songIds: [1], description: "One playlist")
                    }, needsMoreListening: false, isActive: false, onOpen: { _ in }, onPlay: { _ in })
                        .accessibilityIdentifier("smartPlaylistCarousel")
                }
            } else {
                NavigationStack { TransitionStudioRow(collection: .album(42)) }
            }
        }
    }
}
#endif
