import XCTest
@testable import Nod

final class ChatThinkingTests: XCTestCase {
    func testSessionsAreCountedAndPluralised() {
        XCTAssertEqual(ChatThinking.reading(sessions: 1, apps: 0), "Reading 1 session…")
        XCTAssertEqual(ChatThinking.reading(sessions: 6, apps: 0), "Reading 6 sessions…")
    }

    /// The reported gap: the chat reads more than recordings, and the wait used
    /// to name only sessions.
    func testScreenContextIsNamedAlongsideSessions() {
        XCTAssertEqual(ChatThinking.reading(sessions: 3, apps: 2), "Reading 3 sessions and 2 apps…")
        XCTAssertEqual(ChatThinking.reading(sessions: 0, apps: 2), "Reading what was on your screen…")
    }

    func testAnEmptyRetrievalStillSaysSomethingTrue() {
        XCTAssertEqual(ChatThinking.reading(sessions: 0, apps: 0), "Nothing matched — answering from what I have…")
    }
}
