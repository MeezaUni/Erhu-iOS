import XCTest
@testable import Erhu

final class TransferListenerLifecycleTests: XCTestCase {
    func testCancelledFailedAttemptCannotFailAReplacementListener() {
        let occupied = TransferListenerLifecycle()
        XCTAssertEqual(occupied.end(), .startup)
        let replacement = TransferListenerLifecycle()
        XCTAssertTrue(replacement.becomeReady())
        XCTAssertEqual(occupied.end(), .ignored, "EADDRINUSE cancellation is not a live-listener failure")
        XCTAssertFalse(occupied.becomeReady(), "Late readiness must not revive a retired attempt")
        XCTAssertEqual(replacement.end(), .listening, "Real failure of the replacement is still reported")
        XCTAssertEqual(replacement.end(), .ignored)
    }

    func testWaitingAfterReadinessDoesNotConsumeTheEventualFailure() {
        let listener = TransferListenerLifecycle()
        XCTAssertTrue(listener.becomeReady())
        XCTAssertEqual(listener.end(startupOnly: true), .ignored)
        XCTAssertEqual(listener.end(), .listening)
    }

    func testCancellationBeforeReadinessCompletesStartupOnlyOnce() {
        let listener = TransferListenerLifecycle()
        XCTAssertEqual(listener.end(), .startup)
        XCTAssertFalse(listener.becomeReady())
        XCTAssertEqual(listener.end(), .ignored)
    }
}
