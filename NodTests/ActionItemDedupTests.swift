import XCTest
@testable import Nod

final class ActionItemDedupTests: XCTestCase {
    private func item(_ meeting: UUID, _ text: String) -> ActionItem {
        ActionItem.new(meetingID: meeting, userID: UUID(), text: text, deadline: nil, position: 0)
    }

    func testFlagsNearDuplicatesAcrossMeetings() {
        let m1 = UUID(), m2 = UUID()
        let a = item(m1, "Set up the codebase for the new project")
        let b = item(m2, "Set up the codebase for the new project today")
        let flags = ActionItemDedup.flag([a, b])
        XCTAssertEqual(flags[a.id], b.id)
        XCTAssertEqual(flags[b.id], a.id)
    }

    func testDoesNotFlagWithinSameMeeting() {
        let m = UUID()
        let a = item(m, "Review the login PR carefully before merge")
        let b = item(m, "Review the login PR carefully before merge")
        XCTAssertTrue(ActionItemDedup.flag([a, b]).isEmpty)
    }

    func testDoesNotFlagDissimilarTasks() {
        let a = item(UUID(), "Move the release ticket to next sprint")
        let b = item(UUID(), "Mock up the pricing page in Figma")
        XCTAssertTrue(ActionItemDedup.flag([a, b]).isEmpty)
    }

    func testDoesNotFlagShortTasksSharingOneWord() {
        // Only the single token "login" overlaps — below the shared-token floor.
        let a = item(UUID(), "finish login")
        let b = item(UUID(), "design login")
        XCTAssertTrue(ActionItemDedup.flag([a, b]).isEmpty)
    }

    func testDismissedPairIsNotFlagged() {
        let a = item(UUID(), "Schedule the testing environment with Peter")
        let b = item(UUID(), "Schedule the testing environment with Peter Winnie")
        XCTAssertFalse(ActionItemDedup.flag([a, b]).isEmpty)
        let dismissed: Set<String> = [ActionItemDedup.pairKey(a.id, b.id)]
        XCTAssertTrue(ActionItemDedup.flag([a, b], dismissed: dismissed).isEmpty)
    }

    func testPairKeyIsOrderIndependent() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ActionItemDedup.pairKey(a, b), ActionItemDedup.pairKey(b, a))
    }
}
