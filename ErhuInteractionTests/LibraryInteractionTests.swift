import XCTest

final class LibraryInteractionTests: XCTestCase {
    @MainActor private func launch(_ page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--erhu-interaction-probe=" + page]
        app.launch()
        return app
    }

    @MainActor func testSearchClearAndCloseAreTappableWithKeyboardVisible() {
        let app = launch("search")
        app.buttons["openSearchProbe"].tap()
        let field = app.textFields["librarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("needle")
        let clear = app.buttons["searchClearButton"]
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !clear.exists && (field.value as? String) != "needle"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 3), .completed)
        field.typeText("again")
        let close = app.buttons["searchCloseButton"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["openSearchProbe"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
    }

    @MainActor func testBrowseControlsAndRevealedSearchScrollOutOfTheViewport() {
        let app = launch("browse")
        let search = app.buttons["sectionSearchButton"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let field = app.textFields["sectionSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Album")
        // Begin on page content above the keyboard: scrolling up collapses search and
        // dismisses editing while keeping the query, as in the pull-down drawer.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.17)))
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        // A text field can expose its own scroll view. Drag the page content itself.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        start.press(forDuration: 0.05, thenDragTo: end)
        let sort = app.staticTexts["sortProbe"]
        func frame(_ element: XCUIElement) -> String { element.exists ? String(describing: element.frame) : "hidden" }
        let details = "search=\(frame(search)), field=\(frame(field)), sort=\(frame(sort)), keyboard=\(app.keyboards.firstMatch.exists)"
        XCTAssertFalse(search.isHittable, details)
        XCTAssertFalse(field.isHittable, details)
        XCTAssertFalse(sort.isHittable, details)
    }

    @MainActor func testPullRevealsSearchBetweenTheTitleAndControlsAndUpwardSwipeCollapsesIt() {
        let app = launch("browse")
        let searchButton = app.buttons["sectionSearchButton"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
        let field = app.textFields["sectionSearchField"]
        let pageReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            searchButton.isHittable && !field.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pageReady], timeout: 3), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The accessibility element exists before the scroll/bounce animation has
        // finished. Require a usable hit target before checking its final layout.
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 3), .completed)
        XCTAssertLessThan(app.staticTexts["sectionBrowseTitle"].frame.maxY, field.frame.minY)
        XCTAssertGreaterThan(app.staticTexts["sortProbe"].frame.minY, field.frame.maxY)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Pulling reveals search without beginning editing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !field.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
    }

    @MainActor func testCarouselWrapKeepsExactlyThreeDotsAndOneHighlight() {
        let app = launch("carousel")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "smartPlaylistDot-0").firstMatch.waitForExistence(timeout: 10))
        func swipe(left: Bool) {
            // Swipe across the banner, not a small nested Play button with an inherited ID.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.20))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.20))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        func check() {
            let dots = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "smartPlaylistDot-"))
            XCTAssertEqual(dots.count, 3)
            let selected = (0..<dots.count).filter { (dots.element(boundBy: $0).value as? String) == "Current" }
            XCTAssertEqual(selected.count, 1)
        }
        func currentPage() -> Int? {
            (0..<3).first {
                let dot = app.descendants(matching: .any).matching(identifier: "smartPlaylistDot-\($0)").firstMatch
                return (dot.value as? String) == "Current"
            }
        }
        check()
        let initial = currentPage()
        swipe(left: true); check()
        XCTAssertNotEqual(currentPage(), initial)
        for _ in 0..<2 { swipe(left: true); check() }
        XCTAssertEqual(currentPage(), initial, "Swiping past the last playlist returns the one selected dot to the start")
        for _ in 0..<3 { swipe(left: false); check() }
        XCTAssertEqual(currentPage(), initial)
    }

    #if ERHU_ANIMATED_ART
    @MainActor func testAnimatedCoverSearchStaysInTheTopNavigationDrawer() {
        let app = launch("animated-covers")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertLessThan(field.frame.maxY, app.frame.height / 2, "Animated-cover search belongs above the list, away from bottom playback/navigation controls")
    }
    #endif

    @MainActor func testFixTagsScrollingCompactsTheSharedBottomChrome() {
        let app = launch("tools")
        let fraction = app.staticTexts["chromeFraction"]
        XCTAssertTrue(fraction.waitForExistence(timeout: 10))
        // Drag the list gutter so the confidence slider cannot capture the gesture.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.22))
        start.press(forDuration: 0.05, thenDragTo: end)
        start.press(forDuration: 0.05, thenDragTo: end)
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(fraction.label) ?? 0) > 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 3), .completed,
                       "Chrome fraction after list scrolling: \(fraction.label)")
    }

    @MainActor func testTransitionRowHasOnlyItsTitleSummaryAndSwitch() {
        let app = launch("transitions")
        XCTAssertTrue(app.buttons["transitionStudioOpen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Enable transitions for this album"].exists)
        let toggle = app.switches.matching(identifier: "collectionTransitionToggle").firstMatch
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(toggle.isHittable)
        let before = toggle.value as? String
        toggle.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (toggle.value as? String) != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
    }
}
