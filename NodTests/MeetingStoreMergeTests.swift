import XCTest
@testable import Nod

@MainActor
final class MeetingStoreMergeTests: XCTestCase {
    private func makeMeeting(
        id: UUID = UUID(),
        startedAt: Date,
        summary: String = "summary"
    ) -> Meeting {
        Meeting(
            id: id,
            userID: UUID(),
            createdAt: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            title: nil,
            kind: .meeting,
            summary: summary,
            recap: nil,
            language: "en",
            deletedAt: nil
        )
    }

    func testDraftAbsentFromServerIsKept() {
        let older = makeMeeting(startedAt: Date(timeIntervalSince1970: 1000))
        let draft = makeMeeting(startedAt: Date(timeIntervalSince1970: 2000))

        let merged = MeetingStore.merging(rows: [older], drafts: [draft])

        XCTAssertEqual(merged.map(\.id), [draft.id, older.id])
    }

    func testDraftAlreadyOnServerIsNotDuplicated() {
        let id = UUID()
        let serverRow = makeMeeting(id: id, startedAt: Date(timeIntervalSince1970: 1000), summary: "final")
        let draft = makeMeeting(id: id, startedAt: Date(timeIntervalSince1970: 1000), summary: "")

        let merged = MeetingStore.merging(rows: [serverRow], drafts: [draft])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].summary, "final")
    }

    func testResultIsSortedNewestFirst() {
        let a = makeMeeting(startedAt: Date(timeIntervalSince1970: 1000))
        let b = makeMeeting(startedAt: Date(timeIntervalSince1970: 3000))
        let draft = makeMeeting(startedAt: Date(timeIntervalSince1970: 2000))

        let merged = MeetingStore.merging(rows: [a, b], drafts: [draft])

        XCTAssertEqual(merged.map(\.id), [b.id, draft.id, a.id])
    }

    func testEmptyServerKeepsDrafts() {
        let draft = makeMeeting(startedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(MeetingStore.merging(rows: [], drafts: [draft]).map(\.id), [draft.id])
    }

    func testEmptyDraftsKeepsRows() {
        let row = makeMeeting(startedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(MeetingStore.merging(rows: [row], drafts: []).map(\.id), [row.id])
    }
}
