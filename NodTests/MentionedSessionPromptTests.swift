import XCTest
@testable import Nod

/// A per-session chat answers from one transcript. An `@session` in the
/// question is the one thing that widens that, so the widened part has to stay
/// visibly separate — a model that reads another recording as more of this
/// session's transcript will attribute what was said in one meeting to another.
final class MentionedSessionPromptTests: XCTestCase {
    func testNoBlockWhenNothingIsMentioned() {
        let prompt = PromptLibrary.buildChatSystem(
            sessionKind: .meeting,
            title: "Pricing review",
            summary: "We settled on three tiers.",
            transcript: "[Me] What about enterprise?"
        )

        XCTAssertFalse(prompt.contains("OTHER SESSIONS THE USER NAMED"))
    }

    func testMentionedSessionIsSeparatedFromThisSessionsTranscript() {
        let prompt = PromptLibrary.buildChatSystem(
            sessionKind: .meeting,
            title: "Pricing review",
            summary: "We settled on three tiers.",
            transcript: "[Me] What about enterprise?",
            mentionedSessions: "### Kickoff — 1 August 2026\nRECAP: We agreed on the launch date."
        )

        XCTAssertTrue(prompt.contains("OTHER SESSIONS THE USER NAMED"))
        XCTAssertTrue(prompt.contains("Kickoff"))
        XCTAssertTrue(prompt.contains("never present their content as part of the session this chat is about"))
    }

    /// The mentioned block lands after the transcript. It is context brought in
    /// beside this session, and a block ahead of the transcript reads as the
    /// thing being asked about.
    func testMentionedBlockFollowsTheTranscript() throws {
        let prompt = PromptLibrary.buildChatSystem(
            sessionKind: .meeting,
            title: "Pricing review",
            summary: "We settled on three tiers.",
            transcript: "[Me] What about enterprise?",
            mentionedSessions: "### Kickoff — 1 August 2026"
        )

        let transcript = try XCTUnwrap(prompt.range(of: "=== TRANSCRIPT ==="))
        let mentioned = try XCTUnwrap(prompt.range(of: "=== OTHER SESSIONS THE USER NAMED ==="))

        XCTAssertTrue(transcript.lowerBound < mentioned.lowerBound)
    }
}
