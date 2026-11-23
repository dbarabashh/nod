import XCTest
@testable import Nod

final class MeetingArchiveTests: XCTestCase {
    private let meetingID = UUID(uuidString: "6F1C2B3A-0000-4000-8000-00000000000A") ?? UUID()
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func line(_ source: String, _ text: String, at seconds: Double, idx: Int) -> TranscriptArchiveRow {
        TranscriptArchiveRow(
            meetingID: meetingID,
            source: source,
            text: text,
            ts: start.addingTimeInterval(seconds),
            idx: idx
        )
    }

    private func row(
        id: UUID? = nil,
        title: String? = "Weekly sync",
        startedAt: Date?,
        createdAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String? = "",
        recap: MeetingRecap? = nil
    ) -> MeetingArchiveRow {
        MeetingArchiveRow(
            id: id ?? meetingID,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            summary: summary,
            recap: recap
        )
    }

    func testMapsSpeakersAndOffsetsInSpokenOrder() {
        let lines = MeetingArchive.lines(
            [
                line("room", "third", at: 9.5, idx: 2),
                line("me", "first", at: 1.25, idx: 0),
                line("them", "second", at: 4, idx: 1)
            ],
            startedAt: start,
            endedAt: start.addingTimeInterval(12)
        )

        XCTAssertEqual(lines, [
            .init(speaker: .me, startMs: 1250, endMs: 4000, text: "first"),
            .init(speaker: .others, startMs: 4000, endMs: 9500, text: "second"),
            .init(speaker: .others, startMs: 9500, endMs: 12000, text: "third")
        ])
    }

    func testDropsEmptyLinesAndEndsAtTheNextSpokenLine() {
        let lines = MeetingArchive.lines(
            [
                line("me", "hello", at: 2, idx: 0),
                line("them", "   \n", at: 3, idx: 1),
                line("them", "  hi there ", at: 5, idx: 2)
            ],
            startedAt: start,
            endedAt: nil
        )

        XCTAssertEqual(lines, [
            .init(speaker: .me, startMs: 2000, endMs: 5000, text: "hello"),
            .init(speaker: .others, startMs: 5000, endMs: 5000, text: "hi there")
        ])
    }

    func testClampsLinesBeforeTheStartAndEndsNeverBeforeStarts() {
        let lines = MeetingArchive.lines(
            [
                line("me", "early", at: -3, idx: 0),
                line("them", "late write", at: 8, idx: 1),
                line("me", "spoken earlier", at: 6, idx: 2)
            ],
            startedAt: start,
            endedAt: start.addingTimeInterval(4)
        )

        XCTAssertEqual(lines, [
            .init(speaker: .me, startMs: 0, endMs: 6000, text: "early"),
            .init(speaker: .me, startMs: 6000, endMs: 8000, text: "spoken earlier"),
            .init(speaker: .others, startMs: 8000, endMs: 8000, text: "late write")
        ])
    }

    func testLateSegmentLandsWhereItWasSpoken() {
        let lines = MeetingArchive.lines(
            [
                line("me", "opening", at: 1, idx: 0),
                line("them", "reply", at: 7, idx: 1),
                line("them", "late transcription", at: 3, idx: 2)
            ],
            startedAt: start,
            endedAt: start.addingTimeInterval(10)
        )

        XCTAssertEqual(lines, [
            .init(speaker: .me, startMs: 1000, endMs: 3000, text: "opening"),
            .init(speaker: .others, startMs: 3000, endMs: 7000, text: "late transcription"),
            .init(speaker: .others, startMs: 7000, endMs: 10000, text: "reply")
        ])
    }

    func testTitleIsTrimmedAndEmptyWhenMissing() {
        let archive = MeetingArchive.make(
            rows: [row(title: "  Roadmap  ", startedAt: start), row(id: UUID(), title: nil, startedAt: start)],
            transcripts: [:],
            exportedAt: start
        )

        XCTAssertEqual(archive.meetings.map(\.title), ["Roadmap", ""])
    }

    func testStartFallsBackToCreatedAt() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let archive = MeetingArchive.make(
            rows: [row(startedAt: nil, createdAt: created)],
            transcripts: [:],
            exportedAt: start
        )

        XCTAssertEqual(archive.meetings.first?.startedAt, created)
    }

    func testSummaryPrefersTheTypedRecap() {
        let recap = MeetingRecap(sections: [
            .init(title: "Decisions", bullets: [.init(text: "Ship Friday", quote: "let's ship")])
        ])

        XCTAssertEqual(
            MeetingArchive.summary(of: row(startedAt: start, summary: "stale", recap: recap)),
            "**Decisions**\n- Ship Friday \"let's ship\""
        )
    }

    func testSummaryFallsBackToStoredMarkdownAndDropsPlaceholders() {
        let empty = MeetingRecap(sections: [.init(title: "Topics", bullets: [])])

        XCTAssertEqual(MeetingArchive.summary(of: row(startedAt: start, summary: "  - Talked  \n", recap: empty)), "- Talked")
        XCTAssertEqual(MeetingArchive.summary(of: row(startedAt: start, summary: nil)), "")
        XCTAssertEqual(MeetingArchive.summary(of: row(startedAt: start, summary: Meeting.summaryUnavailableNote)), "")
        XCTAssertEqual(MeetingArchive.summary(of: row(startedAt: start, summary: Meeting.recoveredPlaceholder)), "")
    }

    func testEncodesTheContractShape() throws {
        let archive = MeetingArchive.make(
            rows: [row(title: "Sync", startedAt: start, endedAt: nil, summary: "- Done")],
            transcripts: [meetingID: [line("me", "hey", at: 1, idx: 0)]],
            exportedAt: Date(timeIntervalSince1970: 1_760_003_600)
        )

        let json = try XCTUnwrap(String(data: archive.encoded(), encoding: .utf8))

        XCTAssertEqual(json, """
        {
          "exportedAt" : "2025-10-09T09:53:20.000Z",
          "format" : "nod-meetings",
          "meetings" : [
            {
              "endedAt" : null,
              "folder" : null,
              "id" : "6f1c2b3a-0000-4000-8000-00000000000a",
              "startedAt" : "2025-10-09T08:53:20.000Z",
              "summary" : "- Done",
              "title" : "Sync",
              "transcript" : [
                {
                  "endMs" : 1000,
                  "speaker" : "me",
                  "startMs" : 1000,
                  "text" : "hey"
                }
              ]
            }
          ],
          "version" : 1
        }
        """)
    }

    func testEncodesAnEndAsAnISOTimestamp() throws {
        let archive = MeetingArchive.make(
            rows: [row(startedAt: start, endedAt: start.addingTimeInterval(10))],
            transcripts: [:],
            exportedAt: start
        )

        let object = try JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any]
        let meeting = (object?["meetings"] as? [[String: Any]])?.first

        XCTAssertEqual(meeting?["endedAt"] as? String, "2025-10-09T08:53:30.000Z")
    }

    private let me = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA") ?? UUID()
    private let colleague = UUID(uuidString: "00000000-0000-4000-8000-0000000000BB") ?? UUID()

    private func label(_ id: Int, _ name: String, owner: UUID? = nil) -> LabelArchiveRow {
        LabelArchiveRow(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id)) ?? UUID(),
            userID: owner ?? me,
            name: name
        )
    }

    private func link(_ label: LabelArchiveRow) -> MeetingLabelArchiveRow {
        MeetingLabelArchiveRow(meetingID: meetingID, labelID: label.id)
    }

    func testMeetingWithoutAProjectHasNoFolder() {
        let folders = MeetingArchive.folders(links: [], labels: [label(1, "Sales")], ownerID: me)

        XCTAssertNil(folders[meetingID])
    }

    func testOneProjectBecomesTheFolder() {
        let sales = label(1, "  Sales  ")

        XCTAssertEqual(MeetingArchive.folders(links: [link(sales)], labels: [sales], ownerID: me), [meetingID: "Sales"])
    }

    func testSeveralProjectsKeepTheFirstByNameIgnoringCase() {
        let zeta = label(1, "zeta")
        let beta = label(2, "Beta")
        let alpha = label(3, "alpha")

        XCTAssertEqual(
            MeetingArchive.folders(links: [link(zeta), link(beta), link(alpha)], labels: [zeta, beta, alpha], ownerID: me),
            [meetingID: "alpha"]
        )
    }

    func testSameNameFallsBackToTheLowerID() {
        let second = label(9, "Ops")
        let first = label(4, "ops")

        XCTAssertEqual(
            MeetingArchive.folders(links: [link(second), link(first)], labels: [second, first], ownerID: me),
            [meetingID: "ops"]
        )
    }

    func testBlankProjectNameIsNoFolder() {
        let blank = label(1, "   ")

        XCTAssertNil(MeetingArchive.folders(links: [link(blank)], labels: [blank], ownerID: me)[meetingID])
    }

    func testSomeoneElsesProjectIsIgnored() {
        let theirs = label(1, "Acme", owner: colleague)
        let mine = label(2, "Zebra")

        XCTAssertEqual(
            MeetingArchive.folders(links: [link(theirs), link(mine)], labels: [theirs, mine], ownerID: me),
            [meetingID: "Zebra"]
        )
        XCTAssertNil(MeetingArchive.folders(links: [link(theirs)], labels: [theirs], ownerID: me)[meetingID])
    }

    func testEncodesTheFolderName() throws {
        let archive = MeetingArchive.make(
            rows: [row(startedAt: start)],
            transcripts: [:],
            folders: [meetingID: "Hiring"],
            exportedAt: start
        )

        let object = try JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any]
        let meeting = (object?["meetings"] as? [[String: Any]])?.first

        XCTAssertEqual(meeting?["folder"] as? String, "Hiring")
    }

    func testTimestampsKeepMilliseconds() throws {
        let archive = MeetingArchive.make(
            rows: [row(startedAt: start.addingTimeInterval(0.25), endedAt: start.addingTimeInterval(61.5))],
            transcripts: [:],
            exportedAt: start
        )

        let object = try JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any]
        let meeting = (object?["meetings"] as? [[String: Any]])?.first

        XCTAssertEqual(meeting?["startedAt"] as? String, "2025-10-09T08:53:20.250Z")
        XCTAssertEqual(meeting?["endedAt"] as? String, "2025-10-09T08:54:21.500Z")
    }

    func testAMeetingReadTwiceIsExportedOnce() {
        let archive = MeetingArchive.make(
            rows: [
                row(title: "First read", startedAt: start),
                row(title: "Second read", startedAt: start)
            ],
            transcripts: [:],
            exportedAt: start
        )

        XCTAssertEqual(archive.meetings.map(\.title), ["First read"])
    }

    func testDeleteNeedsACurrentExportAndNothingUnsynced() {
        XCTAssertNil(MeetingMigration.deleteBlocker(state: .exported(count: 3), pendingCount: 0))
        XCTAssertEqual(
            MeetingMigration.deleteBlocker(state: .exported(count: 3), pendingCount: 1),
            "Some meetings haven't synced yet, so they aren't in your export. Keep Nod open until they sync, then export again."
        )
        XCTAssertEqual(
            MeetingMigration.deleteBlocker(state: .outdated, pendingCount: 0),
            "Your meetings changed after the export. Export again before deleting."
        )
        XCTAssertEqual(MeetingMigration.deleteBlocker(state: .idle, pendingCount: 0), "Export your meetings first.")
        XCTAssertEqual(MeetingMigration.deleteBlocker(state: .failed("x"), pendingCount: 0), "Export your meetings first.")
    }
}
