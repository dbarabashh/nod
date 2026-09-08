import XCTest
@testable import Nod

final class QuitPolicyTests: XCTestCase {
    func testNothingRecordingQuitsAtOnce() {
        XCTAssertEqual(QuitPolicy.decision(meeting: .idle), .terminate)
    }

    func testARecordingIsEndedOnlyOnAYes() {
        XCTAssertEqual(QuitPolicy.decision(meeting: .recording), .askToEndRecording)
        XCTAssertEqual(QuitPolicy.decision(meeting: .paused), .askToEndRecording)
    }
}
