import XCTest
@testable import Nod

/// The retrieval-skipping shortcut must never overrule what the person pointed
/// at. Two @-mentioned sessions were once answered from the product blurb —
/// "I can only see their titles" — because the needs-sessions flag was made
/// from a rewrite that drops the @ tokens.
final class ChatActingPathTests: XCTestCase {
    private let session = KnowledgeChatStore.SessionRef(id: UUID(), title: "part 1 with Sasha")
    private let folder = SessionLabel(id: UUID(), userID: UUID(), name: "Product", color: "blue", createdAt: nil)

    func testSelfContainedActionSkipsRetrieval() {
        XCTAssertTrue(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: false, asksAboutScreen: false, hasTools: true, pinned: [], scope: []
        ))
    }

    func testMentionedSessionsAlwaysReachRetrieval() {
        XCTAssertFalse(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: false, asksAboutScreen: false, hasTools: true, pinned: [session], scope: []
        ))
    }

    func testScopedFoldersAlwaysReachRetrieval() {
        XCTAssertFalse(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: false, asksAboutScreen: false, hasTools: true, pinned: [], scope: [folder]
        ))
    }

    func testQuestionsAboutSessionsOrScreenNeverSkip() {
        XCTAssertFalse(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: true, asksAboutScreen: false, hasTools: true, pinned: [], scope: []
        ))
        XCTAssertFalse(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: false, asksAboutScreen: true, hasTools: true, pinned: [], scope: []
        ))
        XCTAssertFalse(KnowledgeChatStore.actsWithoutRetrieval(
            needsSessions: false, asksAboutScreen: false, hasTools: false, pinned: [], scope: []
        ))
    }
}
