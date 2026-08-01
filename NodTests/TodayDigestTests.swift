import XCTest
@testable import Nod

final class TodayDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(
        title: String?,
        daysAgo: Double,
        deleted: Bool = false,
        sections: [MeetingRecap.Section] = []
    ) -> Meeting {
        Meeting(
            id: UUID(),
            userID: UUID(),
            createdAt: nil,
            startedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60 + 1800),
            title: title,
            kind: .meeting,
            summary: "",
            recap: sections.isEmpty ? nil : MeetingRecap(sections: sections),
            language: "en",
            speakerNames: nil,
            deletedAt: deleted ? now : nil
        )
    }

    private func item(
        _ text: String,
        meetingID: UUID,
        deadline: String? = nil,
        done: Bool = false,
        position: Int = 0
    ) -> ActionItem {
        ActionItem(
            id: UUID(),
            meetingID: meetingID,
            userID: UUID(),
            text: text,
            deadline: deadline,
            position: position,
            done: done,
            doneAt: nil,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
    }

    // MARK: - Open actions

    func testDoneItemsAreNotOnToday() {
        let m = meeting(title: "Standup", daysAgo: 1)
        let actions = TodayDigest.openActions(
            items: [item("Ship it", meetingID: m.id, done: true), item("Call the bank", meetingID: m.id)],
            meetings: [m],
            now: now
        )

        XCTAssertEqual(actions.map(\.item.text), ["Call the bank"])
    }

    func testTasksFromATrashedSessionAreDropped() {
        let live = meeting(title: "Live", daysAgo: 1)
        let trashed = meeting(title: "Trashed", daysAgo: 1, deleted: true)
        let actions = TodayDigest.openActions(
            items: [item("From trash", meetingID: trashed.id), item("From live", meetingID: live.id)],
            meetings: [live, trashed],
            now: now
        )

        XCTAssertEqual(actions.map(\.item.text), ["From live"])
    }

    func testOverdueTasksSortAheadOfUndatedOnes() {
        let old = meeting(title: "Old", daysAgo: 10)
        let fresh = meeting(title: "Fresh", daysAgo: 0.5)
        let actions = TodayDigest.openActions(
            items: [
                item("No deadline", meetingID: fresh.id),
                item("Late one", meetingID: old.id, deadline: "by tomorrow")
            ],
            meetings: [fresh, old],
            now: now
        )

        XCTAssertEqual(actions.map(\.item.text), ["Late one", "No deadline"])
        XCTAssertEqual(actions.first?.deadline?.urgency, .overdue)
    }

    func testUndatedTasksKeepTheNewerSessionFirst() {
        let older = meeting(title: "Older", daysAgo: 3)
        let newer = meeting(title: "Newer", daysAgo: 1)
        let actions = TodayDigest.openActions(
            items: [item("From older", meetingID: older.id), item("From newer", meetingID: newer.id)],
            meetings: [older, newer],
            now: now
        )

        XCTAssertEqual(actions.map(\.item.text), ["From newer", "From older"])
    }

    func testOpenActionsAreCapped() {
        let m = meeting(title: "Standup", daysAgo: 1)
        let many = (1 ... 20).map { item("Task \($0)", meetingID: m.id, position: $0) }

        XCTAssertEqual(TodayDigest.openActions(items: many, meetings: [m], now: now, limit: 6).count, 6)
    }

    // MARK: - Open points

    private func section(_ title: String, _ bullets: [String]) -> MeetingRecap.Section {
        MeetingRecap.Section(title: title, bullets: bullets.map { MeetingRecap.Bullet(text: $0) })
    }

    func testOpenQuestionsBecomeUnresolvedPoints() {
        let m = meeting(
            title: "Planning",
            daysAgo: 1,
            sections: [
                section("Topics covered", ["We talked about pricing"]),
                section("Open questions", ["Whether to offer an annual discount"])
            ]
        )
        let points = TodayDigest.openPoints(meetings: [m], now: now)

        XCTAssertEqual(points.map(\.text), ["Whether to offer an annual discount"])
    }

    func testSettledSectionsAreNotUnresolved() {
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Decisions made"))
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Topics covered"))
        // An interview recap's "Questions" are asked and answered, not open.
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Questions asked"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Open questions"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Unresolved decisions"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Risks"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Відкриті питання"))
    }

    func testStaleSessionsStopBeingUnresolved() {
        let stale = meeting(
            title: "Ancient",
            daysAgo: 40,
            sections: [section("Open questions", ["Whether to rebuild the pipeline"])]
        )

        XCTAssertTrue(TodayDigest.openPoints(meetings: [stale], now: now).isEmpty)
    }

    func testTrashedSessionsHaveNoOpenPoints() {
        let trashed = meeting(
            title: "Trashed",
            daysAgo: 1,
            deleted: true,
            sections: [section("Open questions", ["Whether to ship"])]
        )

        XCTAssertTrue(TodayDigest.openPoints(meetings: [trashed], now: now).isEmpty)
    }

    func testOpenPointsAreCappedAndNewestFirst() {
        let older = meeting(
            title: "Older",
            daysAgo: 3,
            sections: [section("Open questions", ["Older one", "Older two"])]
        )
        let newer = meeting(
            title: "Newer",
            daysAgo: 1,
            sections: [section("Open questions", ["Newer one", "Newer two"])]
        )
        let points = TodayDigest.openPoints(meetings: [older, newer], now: now, limit: 3)

        XCTAssertEqual(points.map(\.text), ["Newer one", "Newer two", "Older one"])
    }

    // MARK: - Recent sessions

    func testRecentSessionsAreNewestFirstAndExcludeTrash() {
        let older = meeting(title: "Older", daysAgo: 3)
        let newer = meeting(title: "Newer", daysAgo: 1)
        let trashed = meeting(title: "Trashed", daysAgo: 0.5, deleted: true)

        let recent = TodayDigest.recentSessions([older, trashed, newer], limit: 5)

        XCTAssertEqual(recent.map(\.title), ["Newer", "Older"])
    }
}
