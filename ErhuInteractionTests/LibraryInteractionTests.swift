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
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Songs, albums, artists"), object: field)
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
        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp(); scroll.swipeUp()
        XCTAssertFalse(search.isHittable)
        XCTAssertFalse(app.textFields["sectionSearchField"].isHittable)
        XCTAssertFalse(app.staticTexts["sortProbe"].isHittable)
    }

    @MainActor func testCarouselWrapKeepsExactlyThreeDotsAndOneHighlight() {
        let app = launch("carousel")
        let carousel = app.descendants(matching: .any).matching(identifier: "smartPlaylistCarousel").firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 10))
        func check() {
            let dots = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "smartPlaylistDot-"))
            XCTAssertEqual(dots.count, 3)
            let selected = (0..<dots.count).filter { (dots.element(boundBy: $0).value as? String) == "Current" }
            XCTAssertEqual(selected.count, 1)
        }
        check()
        for _ in 0..<4 { carousel.swipeLeft(); check() }
        for _ in 0..<4 { carousel.swipeRight(); check() }
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
        XCTAssertEqual(app.switches.count, 1)
        XCTAssertTrue(app.switches.firstMatch.isHittable)
    }
}
