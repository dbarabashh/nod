import XCTest
@testable import Nod

/// A session somebody shared is the one thing this chat can be pointed at where
/// the reader is in none of the transcript's voices.
///
/// `[Me]` means the microphone that recorded the session. Every prompt used to
/// say it meant the person asking, and the profile block above the transcript
/// named them — so a question about somebody else's recording was answered as
/// though the reader had been in the room.
final class SharedSessionAttributionTests: XCTestCase {
    private func prompt(host: String?) -> String {
        PromptLibrary.buildChatSystem(
            sessionKind: .meeting,
            title: "Exploring ads agency support",
            summary: "The user wants to think it over before deciding.",
            transcript: "[Me · Vlad Kampov]: I need to think about it",
            host: host
        )
    }

    /// Asserted on fragments rather than whole sentences: the wording of a
    /// prompt is rewritten often, and a test that pins the prose fails on every
    /// rewrite without anything having changed.
    func testTheOwnerIsNamedAndTheReaderIsExcluded() {
        let text = prompt(host: "Vlad Kampov")

        XCTAssertTrue(text.contains("Vlad Kampov recorded it"))
        XCTAssertTrue(text.contains("[Me · Vlad Kampov] is Vlad Kampov"))
        XCTAssertTrue(text.contains("NOT in it"))
    }

    /// The recap is in this prompt too, and it was written for its owner in the
    /// second person. Left unsaid, "the user wants to think it over" is read as
    /// the person asking.
    func testTheRecapsSecondPersonIsBoundToTheOwner() {
        XCTAssertTrue(prompt(host: "Vlad Kampov").contains("The RECAP was written for Vlad Kampov"))
    }

    /// The common case is unchanged: on your own session you are `[Me]`, and a
    /// prompt that names you as a third party reads as somebody else's meeting.
    func testYourOwnSessionNamesNobody() {
        let text = prompt(host: nil)

        XCTAssertTrue(text.contains("one meeting they recorded"))
        XCTAssertFalse(text.contains("WHOSE MEETING THIS IS"))
    }

    /// The profile block is prepended to prompts that have no transcript at all,
    /// and it is the reader's own name. Binding `[Me]` to it there was the bug:
    /// which voice the tag belongs to is known where the session is.
    func testTheProfileBlockDoesNotSayWhoMeIs() {
        let block = Profile(userID: UUID(), displayName: "Dima").promptBlock

        XCTAssertTrue(block.contains("Dima"))
        XCTAssertFalse(block.contains("[Me]"))
    }
}
