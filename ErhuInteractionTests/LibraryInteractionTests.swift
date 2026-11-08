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
        XCTAssertTrue(app.textFields["sectionSearchField"].waitForExistence(timeout: 5))
        // Dismiss the keyboard without closing the field, then browse farther down.
        app.keyboards.buttons["Search"].tap()
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        // A text field can expose its own scroll view. Drag the page content itself.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        start.press(forDuration: 0.05, thenDragTo: end)
        let field = app.textFields["sectionSearchField"]
        let sort = app.staticTexts["sortProbe"]
        let details = "search=\(search.frame), field=\(field.frame), sort=\(sort.frame), keyboard=\(app.keyboards.firstMatch.exists)"
        XCTAssertFalse(search.isHittable, details)
        XCTAssertFalse(field.isHittable, details)
        XCTAssertFalse(sort.isHittable, details)
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

    @MainActor func testFixTagsScrollingCompactsTheSharedBottomChrome() {
        let app = launch("tools")
        let fraction = app.staticTexts["chromeFraction"]
        XCTAssertTrue(fraction.waitForExistence(timeout: 10))
        app.swipeUp(); app.swipeUp()
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(fraction.label) ?? 0) > 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 3), .completed)
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
        XCTAssertNotEqual(toggle.value as? String, before)
    }
}
