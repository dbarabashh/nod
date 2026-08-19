import XCTest
@testable import Nod

/// The sources pill hides things on purpose, which is what makes its ordering
/// worth pinning: a source past `listLimit` is named only in a muted line, and
/// one past `markLimit` is not drawn at all.
final class ChatSourcesRowTests: XCTestCase {
    private func session(_ title: String) -> KnowledgeChatStore.SessionRef {
        KnowledgeChatStore.SessionRef(id: UUID(), title: title)
    }

    private func app(_ title: String, bundleID: String) -> KnowledgeChatStore.SessionRef {
        KnowledgeChatStore.SessionRef(id: UUID(), title: title, bundleID: bundleID)
    }

    /// Sessions are the spine of the answer and they open; an app is a label.
    /// Ordering apps first would put the unclickable ones in the marks and
    /// leave the checkable ones for the muted line.
    func testSessionsComeBeforeApps() {
        let mixed = [
            app("Google Chrome", bundleID: "com.google.Chrome"),
            session("Ads agency call"),
            app("Slack", bundleID: "com.tinyspeck.slackmacgap"),
            session("Pricing review")
        ]

        let ordered = ChatSourcesRow.ordered(mixed)

        XCTAssertEqual(ordered.map(\.title), ["Ads agency call", "Pricing review", "Google Chrome", "Slack"])
    }

    func testOrderingKeepsEverySource() {
        let sources = (0 ..< 9).map { session("S\($0)") } + [app("Chrome", bundleID: "com.google.Chrome")]

        XCTAssertEqual(ChatSourcesRow.ordered(sources).count, sources.count)
    }

    /// The relative order inside each kind is retrieval's, which is what makes
    /// the first mark the strongest match rather than an alphabetical accident.
    func testRetrievalOrderSurvivesWithinEachKind() {
        let sources = [session("first"), session("second"), session("third")]

        XCTAssertEqual(ChatSourcesRow.ordered(sources).map(\.title), ["first", "second", "third"])
    }

    /// A pill wearing every mark is the strip it replaced.
    func testTheMarkAndListLimitsStayShortEnoughToCollapse() {
        XCTAssertLessThanOrEqual(ChatSourcesRow.markLimit, ChatSourcesRow.listLimit)
        XCTAssertLessThanOrEqual(ChatSourcesRow.listLimit, 6)
    }
}
