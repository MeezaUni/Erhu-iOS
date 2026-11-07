import SwiftUI
import UIKit

/// Sorts and filters scroll away with the page. Pulling past the top reveals a search for this page only.
struct LibraryBrowseScrollView<Controls: View, Content: View>: View {
    let title: String
    var isTabRoot = false
    var showsControls = true
    @Binding var query: String
    @Binding var showsSearch: Bool
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    var body: some View {
        scroll
            .modifier(RevealSectionSearch { revealSearch() })
            .scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .tracksLibraryScrolling()
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var searchAndControls: some View {
        if showsSearch || showsControls {
            VStack(spacing: 10) {
                if showsSearch {
                    GlassSearchField(text: $query, prompt: "Search \(title.lowercased())", focused: $searchFocused,
                                     close: { closeSearch() }, identifier: "sectionSearchField")
                }
                if showsControls {
                    HStack(alignment: .top, spacing: 10) {
                        BrowseControlFlow { controls }
                        Button { revealSearch(); searchFocused = true } label: {
                            Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Search \(title.lowercased())")
                        .accessibilityIdentifier("sectionSearchButton")
                    }
                }
            }
            .padding(.horizontal, Spacing.gutter).padding(.vertical, 8)
            .accessibilityIdentifier("sectionBrowseControls")
        }
    }

    @ViewBuilder private var scroll: some View {
        if isTabRoot {
            LibraryRootScrollView { pageContent }
        } else {
            ScrollView { pageContent }
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if #unavailable(iOS 18.0) {
                LegacySearchPullProbe { revealSearch() }.frame(height: 0)
            }
            searchAndControls
            Text(title).font(.largeTitle.bold())
                .padding(.horizontal, Spacing.gutter)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func closeSearch() {
        searchFocused = false; query = ""
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSearch = false }
    }

    private func revealSearch() {
        guard !showsSearch else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSearch = true }
    }
}

/// Wrap filters on small phones and at large text sizes instead of hiding them offscreen.
private struct BrowseControlFlow: Layout {
    private let gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(proposal.width ?? 320, 1)
        let items = arrangement(width: width, subviews: subviews)
        return CGSize(width: width, height: items.map { $0.maxY }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let items = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + gap; rowHeight = 0 }
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}

struct LibrarySortMenu: View {
    @Binding var selection: String
    let options: [LibrarySort]

    var body: some View {
        Menu {
            Picker("Sort by", selection: $selection) {
                ForEach(options, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        } label: {
            BrowseControlLabel(title: (LibrarySort(rawValue: selection) ?? .title).shortLabel, icon: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort by \((LibrarySort(rawValue: selection) ?? .title).label)")
    }
}

struct BrowseControlLabel: View {
    let title: String
    let icon: String
    var selected = false

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .foregroundStyle(.primary)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.35 : 0.15)))
    }
}

enum LibrarySearchReveal {
    static func shouldReveal(offset: Double, topInset: Double) -> Bool {
        offset.isFinite && topInset.isFinite && offset + topInset < -32
    }
}

private struct RevealSectionSearch: ViewModifier {
    var reveal: () -> Void
    @State private var triggered = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                LibrarySearchReveal.shouldReveal(offset: geometry.contentOffset.y, topInset: geometry.contentInsets.top)
            } action: { _, pulled in
                if pulled && !triggered { triggered = true; reveal() }
            }
            .onScrollPhaseChange { _, phase in if phase == .idle { triggered = false } }
        } else {
            content
        }
    }
}

/// iOS 17 fallback observes the enclosing scroll view without replacing its delegate or gestures.
private struct LegacySearchPullProbe: UIViewRepresentable {
    var reveal: () -> Void
    func makeUIView(context: Context) -> ProbeView { let view = ProbeView(); view.reveal = reveal; return view }
    func updateUIView(_ uiView: ProbeView, context: Context) { uiView.reveal = reveal }
    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.observation = nil; uiView.reveal = nil }

    final class ProbeView: UIView {
        var reveal: (() -> Void)?
        var observation: NSKeyValueObservation?
        private var triggered = false
        private weak var observedScroll: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard window != nil else { observation = nil; observedScroll = nil; return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    guard observedScroll !== scroll else { return }
                    observedScroll = scroll
                    observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                        if !scroll.isDragging { self?.triggered = false; return }
                        guard self?.triggered == false,
                              LibrarySearchReveal.shouldReveal(offset: scroll.contentOffset.y, topInset: scroll.adjustedContentInset.top)
                        else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.triggered else { return }
                            self.triggered = true; self.reveal?()
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
