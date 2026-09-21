import XCTest
@testable import Nod

@MainActor
final class PastAnswerTests: XCTestCase {
    private func decode(_ json: String) throws -> [KnowledgeThreadStore.PastAnswer] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([KnowledgeThreadStore.PastAnswer].self, from: Data(json.utf8))
    }

    /// A row that fails to decode drops the whole block without a word, so the
    /// three shapes a row takes are pinned: a chat answer, an agent's report
    /// with nothing cited, and an answer that cited an app.
    func testDecodesAChatAnswerAnAgentReportAndAnAppSource() throws {
        let rows = try decode("""
        [
          {"content": "Acme shipped the export.", "created_at": "2026-09-18T09:00:00Z",
           "sources": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Acme sync"}],
           "knowledge_threads": {"title": "Acme status", "beat_id": null}},
          {"content": "Nothing new on Acme.", "created_at": "2026-09-18T09:00:00Z",
           "sources": [],
           "knowledge_threads": {"title": "Morning brief", "beat_id": "7F9619FF-8B86-D011-B42D-00C04FC964FF"}},
          {"content": "You had the Acme board open.", "created_at": "2026-09-18T09:00:00Z",
           "sources": [{"id": "8F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Jira", "bundleID": "com.atlassian.jira"}],
           "knowledge_threads": {"title": "", "beat_id": null}}
        ]
        """)

        XCTAssertEqual(rows.map(\.thread.title), ["Acme status", "Morning brief", ""])
        XCTAssertNil(rows[0].thread.beatID)
        XCTAssertNotNil(rows[1].thread.beatID)
        XCTAssertTrue(rows[1].sources.isEmpty)
        XCTAssertEqual(rows[2].sources.first?.bundleID, "com.atlassian.jira")
    }

    func testANameBecomesOneQuotedFilter() {
        XCTAssertEqual(
            KnowledgeThreadStore.mentionFilters(for: ["Anna Kovalenko", "pre-sales"]),
            ["content.ilike.\"*Anna Kovalenko*\"", "content.ilike.\"*pre-sales*\""]
        )
    }

    /// Commas, quotes and parentheses end a PostgREST clause, so they never
    /// reach one — and "Node.js" still finds itself through the wildcard.
    func testNothingThatEndsAClauseSurvives() {
        XCTAssertEqual(
            KnowledgeThreadStore.mentionFilters(for: ["Node.js", "a\",id.eq.1)", "AT&T"]),
            ["content.ilike.\"*Node*js*\"", "content.ilike.\"*a**id*eq*1**\"", "content.ilike.\"*AT*T*\""]
        )
    }

    func testNamesTooShortToMeanAnythingAreDropped() {
        XCTAssertTrue(KnowledgeThreadStore.mentionFilters(for: ["AI", "", "  "]).isEmpty)
    }
}
