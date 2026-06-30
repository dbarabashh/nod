import XCTest
@testable import Nod

final class MeetingRecapTests: XCTestCase {
    private func decode(_ json: String) throws -> MeetingRecap {
        try JSONDecoder().decode(MeetingRecap.self, from: Data(json.utf8))
    }

    func testDecodesActionItemsArrayAlongsideSections() throws {
        let recap = try decode("""
        {"sections":[{"title":"Topics covered","bullets":[{"text":"Talked auth","quote":null}]}],
         "action_items":[{"text":"Move the release ticket","deadline":null},
                         {"text":"Mock up pricing","deadline":"by Friday"}]}
        """)

        XCTAssertEqual(recap.sections.count, 1)
        XCTAssertEqual(recap.actionItems.count, 2)
        XCTAssertEqual(recap.actionItems[0].text, "Move the release ticket")
        XCTAssertNil(recap.actionItems[0].deadline)
        XCTAssertEqual(recap.actionItems[1].deadline, "by Friday")
    }

    func testActionItemsAreNotRenderedIntoMarkdown() throws {
        let recap = try decode("""
        {"sections":[{"title":"Decisions made","bullets":[{"text":"Ship next week","quote":null}]}],
         "action_items":[{"text":"Move the release ticket","deadline":null}]}
        """)

        let md = recap.toMarkdown()
        XCTAssertTrue(md.contains("**Decisions made**"))
        XCTAssertFalse(md.contains("Move the release ticket"))
        XCTAssertFalse(md.localizedCaseInsensitiveContains("action items"))
    }

    func testMissingActionItemsDecodesToEmpty() throws {
        let recap = try decode("""
        {"sections":[{"title":"Topics covered","bullets":[{"text":"x","quote":null}]}]}
        """)
        XCTAssertTrue(recap.actionItems.isEmpty)
    }

    func testLegacyActionsMapIntoActionItems() throws {
        let recap = try decode("""
        {"topics":[{"text":"Intro","quote":null}],
         "actions":[{"owner":"Priya","task":"move the ticket","when":"Friday"},
                    {"owner":null,"task":"scrub the YAML","when":null}]}
        """)

        // Legacy actions no longer surface as a section…
        XCTAssertFalse(recap.sections.contains { $0.title == "Action items" })
        // …they map into the structured array, owner folded into text.
        XCTAssertEqual(recap.actionItems.count, 2)
        XCTAssertEqual(recap.actionItems[0].text, "Priya — move the ticket")
        XCTAssertEqual(recap.actionItems[0].deadline, "Friday")
        XCTAssertEqual(recap.actionItems[1].text, "scrub the YAML")
    }
}
