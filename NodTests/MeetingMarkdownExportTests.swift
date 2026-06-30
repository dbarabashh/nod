import XCTest
@testable import Nod

final class MeetingMarkdownExportTests: XCTestCase {
    private func makeMeeting(
        title: String?,
        summary: String,
        start: Date,
        end: Date
    ) -> Meeting {
        Meeting(
            id: UUID(),
            userID: UUID(),
            createdAt: nil,
            startedAt: start,
            endedAt: end,
            title: title,
            kind: .meeting,
            summary: summary,
            recap: nil,
            language: "uk",
            deletedAt: nil
        )
    }

    private func record(_ meetingID: UUID, source: String, text: String, ts: Date) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID(),
            meetingID: meetingID,
            userID: UUID(),
            createdAt: nil,
            source: source,
            text: text,
            ts: ts,
            idx: 0,
            speaker: nil
        )
    }

    func testRenderIncludesFrontmatterTitleSummaryAndTranscript() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(
            title: "Weekly Sync",
            summary: "**Decisions**\n- Ship Friday",
            start: start,
            end: start.addingTimeInterval(125)
        )
        let transcript = [
            record(meeting.id, source: "me", text: "Let's start.", ts: start.addingTimeInterval(5)),
            record(meeting.id, source: "them", text: "Sounds good.", ts: start.addingTimeInterval(11))
        ]

        let md = MeetingMarkdownExport.render(meeting: meeting, transcript: transcript, tags: ["Project X", "team"])

        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("title: \"Weekly Sync\""))
        XCTAssertTrue(md.contains("language: uk"))
        XCTAssertTrue(md.contains("kind: meeting"))
        XCTAssertTrue(md.contains("source: Nod"))
        XCTAssertTrue(md.contains("duration: 2m"))
        XCTAssertTrue(md.contains("  - Project-X"))
        XCTAssertTrue(md.contains("# Weekly Sync"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("- Ship Friday"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("[00:05] **Me**: Let's start."))
        XCTAssertTrue(md.contains("[00:11] **Them**: Sounds good."))
    }

    private func action(_ meetingID: UUID, text: String, deadline: String?, done: Bool, position: Int) -> ActionItem {
        ActionItem(
            id: UUID(),
            meetingID: meetingID,
            userID: UUID(),
            text: text,
            deadline: deadline,
            position: position,
            done: done,
            doneAt: done ? Date(timeIntervalSince1970: 1_700_000_500) : nil,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
    }

    func testRenderIncludesActionItemsAsTaskList() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(title: "Sync", summary: "**Decisions**\n- Ship Friday", start: start, end: start.addingTimeInterval(60))
        let items = [
            action(meeting.id, text: "Move the release ticket", deadline: nil, done: false, position: 0),
            action(meeting.id, text: "Mock up the pricing page", deadline: "by Friday", done: true, position: 1)
        ]

        let md = MeetingMarkdownExport.render(meeting: meeting, transcript: [], tags: [], actionItems: items)

        XCTAssertTrue(md.contains("## Action items"))
        XCTAssertTrue(md.contains("- [ ] Move the release ticket"))
        XCTAssertTrue(md.contains("- [x] Mock up the pricing page (by Friday)"))
    }

    func testNoActionItemsSectionWhenEmpty() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(title: "Sync", summary: "x", start: start, end: start)
        let md = MeetingMarkdownExport.render(meeting: meeting, transcript: [])
        XCTAssertFalse(md.contains("## Action items"))
    }

    func testUntitledFallbackAndNoTranscriptSection() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(title: nil, summary: "", start: start, end: start)
        let md = MeetingMarkdownExport.render(meeting: meeting, transcript: [])

        XCTAssertTrue(md.contains("# Untitled meeting"))
        XCTAssertFalse(md.contains("title:"))
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertFalse(md.contains("## Transcript"))
    }

    func testYamlTitleEscapesQuotes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(title: "Re: \"Q3\" plan", summary: "x", start: start, end: start)
        let md = MeetingMarkdownExport.render(meeting: meeting, transcript: [])
        XCTAssertTrue(md.contains(#"title: "Re: \"Q3\" plan""#))
    }

    func testFileNameSanitisesPathHostileCharacters() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = makeMeeting(title: "Plan: A/B test?", summary: "", start: start, end: start)
        let name = MeetingMarkdownExport.fileName(for: meeting)
        XCTAssertEqual(name, "Plan_ A_B test.md")
    }

    func testOffsetLabelRollsOverToHours() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(MeetingMarkdownExport.offsetLabel(from: start, to: Date(timeIntervalSince1970: 65)), "01:05")
        XCTAssertEqual(MeetingMarkdownExport.offsetLabel(from: start, to: Date(timeIntervalSince1970: 3725)), "1:02:05")
    }
}
