import XCTest
@testable import Nod

/// The arrangement behind the expanded "Waiting on you" list: what the reader
/// sees as headers, and in what order.
final class ActionGroupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ title: String?, daysAgo: Double) -> Meeting {
        Meeting(
            id: UUID(),
            userID: UUID(),
            createdAt: nil,
            startedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60 + 1800),
            title: title,
            kind: .meeting,
            summary: "",
            recap: nil,
            language: "en",
            speakerNames: nil,
            deletedAt: nil
        )
    }

    private func item(_ text: String, meetingID: UUID) -> ActionItem {
        ActionItem(
            id: UUID(), meetingID: meetingID, userID: UUID(), text: text,
            deadline: nil, kind: .action, status: .confirmed, source: .recap,
            revisionOf: nil, evidenceIdx: nil, evidenceQuote: nil, position: 0,
            done: false, doneAt: nil, loopState: .open,
            externalProvider: nil, externalKey: nil, externalURL: nil, externalCreatedAt: nil,
            createdAt: nil, updatedAt: nil, deletedAt: nil
        )
    }

    /// Groups appear in the order their first item does, and items keep the
    /// order they arrived in. The caller sorted for recency; re-sorting here
    /// would move commitments the person was just looking at.
    func testKeepsIncomingOrderOfGroupsAndItems() {
        let pricing = meeting("Pricing and Teams Billing Decisions", daysAgo: 1)
        let activation = meeting("Pricing Updates and Activation Strategy", daysAgo: 2)
        let items = [
            item("Research cheaper LLMs", meetingID: pricing.id),
            item("Write the annual-prepay proposal", meetingID: pricing.id),
            item("Review what shipped", meetingID: activation.id),
            item("Ship the current functionality", meetingID: pricing.id)
        ]

        let groups = ActionGrouping.bySession(
            items,
            meetings: [pricing.id: pricing, activation.id: activation]
        )

        XCTAssertEqual(groups.map(\.title), [
            "Pricing and Teams Billing Decisions",
            "Pricing Updates and Activation Strategy"
        ])
        XCTAssertEqual(groups[0].items.map(\.text), [
            "Research cheaper LLMs",
            "Write the annual-prepay proposal",
            "Ship the current functionality"
        ])
        XCTAssertEqual(groups[1].items.map(\.text), ["Review what shipped"])
        XCTAssertEqual(groups.map(\.id), [pricing.id, activation.id])
    }

    /// An untitled session already renders as "Meeting on 3 Sep", so a date
    /// beside it would print the same day twice.
    func testUntitledSessionCarriesNoDateSubtitle() {
        let untitled = meeting(nil, daysAgo: 0)
        let titled = meeting("Weekly sync", daysAgo: 0)

        let groups = ActionGrouping.bySession(
            [item("a", meetingID: untitled.id), item("b", meetingID: titled.id)],
            meetings: [untitled.id: untitled, titled.id: titled]
        )

        XCTAssertNil(groups[0].subtitle)
        XCTAssertNotNil(groups[1].subtitle)
    }

    /// A commitment whose meeting is not in the cache still groups — it carries
    /// its own `meetingID`, so it never falls out of the list it belongs to.
    func testItemsSurviveAMissingMeeting() {
        let orphanID = UUID()

        let groups = ActionGrouping.bySession([item("Chase the invoice", meetingID: orphanID)], meetings: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, orphanID)
        XCTAssertEqual(groups[0].title, "Another session")
        XCTAssertNil(groups[0].subtitle)
    }

    func testNoItemsMakeNoGroups() {
        XCTAssertTrue(ActionGrouping.bySession([], meetings: [:]).isEmpty)
    }
}
