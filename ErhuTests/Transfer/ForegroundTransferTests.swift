import XCTest
@testable import Erhu

final class ForegroundTransferTests: XCTestCase {
    func testExplicitForegroundSessionDoesNotExpireDuringALongTransferButStopRevokesIt() {
        let session = TransferSession.foreground(nowMs: 1000)
        XCTAssertTrue(session.isOpen(1000 + 4 * 60 * 60 * 1000))
        session.close()
        XCTAssertFalse(session.isOpen(1001))
    }

    func testTransientAddressLookupDoesNotStopTransferButSustainedLossDoes() {
        var continuity = TransferNetworkContinuity()
        XCTAssertFalse(continuity.shouldStop(address: nil, expected: "192.168.1.2"))
        XCTAssertFalse(continuity.shouldStop(address: nil, expected: "192.168.1.2"))
        XCTAssertFalse(continuity.shouldStop(address: "192.168.1.2", expected: "192.168.1.2"))
        XCTAssertFalse(continuity.shouldStop(address: "192.168.1.3", expected: "192.168.1.2"))
        XCTAssertFalse(continuity.shouldStop(address: "192.168.1.3", expected: "192.168.1.2"))
        XCTAssertTrue(continuity.shouldStop(address: "192.168.1.3", expected: "192.168.1.2"))
    }
}
