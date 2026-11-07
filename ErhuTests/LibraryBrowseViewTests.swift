import XCTest
import SwiftUI
import UIKit
import Observation
@testable import Erhu

final class LibraryBrowseViewTests: XCTestCase {
    @MainActor
    func testPullAtTopRevealsSectionSearchInMountedScrollView() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native scroll geometry is available on iOS 18 and later") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        let search = SearchState()
        let router = AppRouter()
        router.select(.albums)
        let host = UIHostingController(rootView: NavigationStack {
            LibraryBrowseScrollView(title: "Albums", query: Binding(get: { search.query }, set: { search.query = $0 }),
                                    showsSearch: Binding(get: { search.revealed }, set: { search.revealed = $0 })) {
                Text("Sort")
            } content: {
                LazyVStack { ForEach(0..<100) { Text("Album \($0)").frame(height: 44) } }
            }
        }.environment(router).environment(LibraryChromeState()).environment(\.artworkSection, .albums))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        func verticalScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > 2_000 { return scroll }
            return view.subviews.lazy.compactMap { verticalScroll($0) }.first
        }
        for _ in 0..<150 {
            if verticalScroll(host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try XCTUnwrap(verticalScroll(host.view))
        XCTAssertFalse(search.revealed)
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(search.revealed, "Normal scrolling must not open search")
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top - 60), animated: false)
        for _ in 0..<100 {
            if search.revealed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(search.revealed)
        XCTAssertEqual(search.query, "", "Pulling down must not invent or reuse a global query")
        let before = scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scroll.adjustedContentInset.top, before, accuracy: 1, "The controls are page content, not a changing pinned safe-area inset")
    }
}

@MainActor
@Observable
private final class SearchState {
    var query = ""
    var revealed = false
}
