import XCTest
@testable import Nod

/// `ActionItemStore.items` is a local copy of one query and nothing else. What
/// `saveExtracted` appends to it after a finalize has to be what a refresh
/// would bring back, or the checklist disagrees with itself across a relaunch.
@MainActor
final class ActionItemCacheTests: XCTestCase {
    private func item(
        kind: ActionItem.Kind = .action,
        status: ActionItem.Status = .confirmed,
        source: ActionItem.Source = .recap
    ) -> ActionItem {
        ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Send the updated deck",
            deadline: nil,
            position: 0,
            kind: kind,
            status: status,
            source: source
        )
    }

    func testAConfirmedTaskIsCached() {
        XCTAssertTrue(ActionItemStore.belongsInCache(item()))
        XCTAssertTrue(ActionItemStore.belongsInCache(item(status: .confirmed, source: .live)))
    }

    func testALiveGuessTheRecapRetiredIsNotCached() {
        XCTAssertFalse(ActionItemStore.belongsInCache(item(status: .dropped, source: .live)))
        XCTAssertFalse(ActionItemStore.belongsInCache(item(status: .proposed, source: .live)))
        XCTAssertFalse(ActionItemStore.belongsInCache(item(status: .superseded, source: .live)))
    }

    func testWhatTheMeetingNotedIsNotATaskAndIsNotCached() {
        for kind in [ActionItem.Kind.question, .decision, .risk, .followUp, .theirs] {
            XCTAssertFalse(
                ActionItemStore.belongsInCache(item(kind: kind, source: .live)),
                "\(kind.rawValue) is not the user's to do"
            )
        }
    }
}
