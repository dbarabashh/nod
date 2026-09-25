import XCTest
@testable import Nod

@MainActor
final class RecapSectionKindTests: XCTestCase {
    private func meeting(_ recap: MeetingRecap, summary: String? = nil) -> Meeting {
        .newCompleted(
            userID: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            summary: summary ?? recap.toMarkdown(),
            language: "en",
            recap: recap
        )
    }

    private func section(_ title: String, _ kind: MeetingRecap.Section.Kind?, bullets: Int = 2) -> MeetingRecap.Section {
        MeetingRecap.Section(
            title: title,
            bullets: (0 ..< bullets).map { MeetingRecap.Bullet(text: "\(title) point \($0)") },
            kind: kind
        )
    }

    func testTopicHeadingsThatSoundLikeSignalsAreNotCounted() {
        let recap = MeetingRecap(sections: [
            section("Marketing spending", .topic),
            section("Відкриття офісу", .topic),
            section("Погодження бюджету", .topic),
            section("Decisions", .decisions, bullets: 1),
            section("Unresolved", .unresolved, bullets: 3)
        ], actionItems: [])

        let knowledge = SessionKnowledge.of(meeting(recap))

        XCTAssertEqual(knowledge.decisions, 1)
        XCTAssertEqual(knowledge.unresolved, 3)
    }

    func testRecapsWithoutKindStillCountByHeading() {
        let recap = MeetingRecap(sections: [
            section("Decisions made", nil, bullets: 2),
            section("Open questions", nil, bullets: 1)
        ], actionItems: [])

        let knowledge = SessionKnowledge.of(meeting(recap))

        XCTAssertEqual(knowledge.decisions, 2)
        XCTAssertEqual(knowledge.unresolved, 1)
    }

    func testKindDecodesAndUnknownValuesFallBackToNil() throws {
        let json = """
        {"sections":[{"title":"Plan","kind":"topic","bullets":[{"text":"a","quote":null}]},
                     {"title":"Other","kind":"something-new","bullets":[{"text":"b","quote":null}]},
                     {"title":"Old","bullets":[{"text":"c","quote":null}]}]}
        """
        let recap = try JSONDecoder().decode(MeetingRecap.self, from: Data(json.utf8))

        XCTAssertEqual(recap.sections.map(\.kind), [.topic, nil, nil])
        XCTAssertEqual(recap.sections.map(\.title), ["Plan", "Other", "Old"])
    }

    func testEditingABulletKeepsTheSectionKind() {
        let recap = MeetingRecap(sections: [section("Decisions", .decisions)], actionItems: [])

        let edited = recap.replacing(MeetingRecap.BulletID(section: 0, bullet: 0), with: "Changed")

        XCTAssertEqual(edited.sections.first?.kind, .decisions)
    }

    func testLongRecapGroundsSettledSectionsFirstWithinItsShare() {
        let longTopic = MeetingRecap.Section(
            title: "Roadmap",
            bullets: (0 ..< 200).map { MeetingRecap.Bullet(text: "Roadmap detail number \($0) with some words") },
            kind: .topic
        )
        let recap = MeetingRecap(sections: [
            section("Overview", .overview, bullets: 1),
            longTopic,
            section("Decisions", .decisions, bullets: 1)
        ], actionItems: [])

        let grounded = KnowledgeChatStore.groundingRecap(of: meeting(recap))

        XCTAssertLessThanOrEqual(grounded.count, KnowledgeChatStore.recapShare)
        XCTAssertTrue(grounded.contains("Decisions point 0"))
        let decisions = grounded.range(of: "**Decisions**")
        let roadmap = grounded.range(of: "**Roadmap**")
        XCTAssertNotNil(decisions)
        if let decisions, let roadmap { XCTAssertLessThan(decisions.lowerBound, roadmap.lowerBound) }
    }

    func testShortRecapIsGroundedUnchanged() {
        let recap = MeetingRecap(sections: [section("Overview", .overview, bullets: 1)], actionItems: [])
        let meeting = meeting(recap)

        XCTAssertEqual(KnowledgeChatStore.groundingRecap(of: meeting), meeting.summary)
    }
}

extension RecapSectionKindTests {
    func testHandEditedLongSummaryIsGroundedAsEdited() {
        let recap = MeetingRecap(sections: [
            MeetingRecap.Section(
                title: "Roadmap",
                bullets: (0 ..< 200).map { MeetingRecap.Bullet(text: "Roadmap detail number \($0) with some words") },
                kind: .topic
            )
        ], actionItems: [])
        let edited = "EDITED BY HAND\n" + recap.toMarkdown()

        let grounded = KnowledgeChatStore.groundingRecap(of: meeting(recap, summary: edited))

        XCTAssertTrue(grounded.hasPrefix("EDITED BY HAND"))
        XCTAssertEqual(grounded.count, KnowledgeChatStore.recapShare)
    }
}
