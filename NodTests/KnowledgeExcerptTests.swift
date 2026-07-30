import XCTest
@testable import Nod

/// `readable` produces the evidence passage shown under a cross-session answer.
/// The indexed chunks it reads are raw transcript, so every tag shape the
/// transcript can carry has to be handled here or it reaches the user.
@MainActor
final class KnowledgeExcerptTests: XCTestCase {
    func testBareRoutingTagsAreStripped() {
        XCTAssertEqual(
            KnowledgeChatStore.readable("[Them]: we ship on Friday"),
            "we ship on Friday"
        )
        XCTAssertEqual(KnowledgeChatStore.readable("[Me]: agreed"), "agreed")
    }

    /// The regression: diarization narrows the tag, and matching the two bare
    /// forms stopped catching it — the excerpt rendered with the tag intact.
    func testAClusterNumberIsStrippedWithItsTag() {
        XCTAssertEqual(
            KnowledgeChatStore.readable("[Them · Speaker 2]: we ship on Friday"),
            "we ship on Friday"
        )
    }

    /// A name is not a routing tag — it is the answer to "who said this".
    func testANamedSpeakerSurvivesAsThePerson() {
        XCTAssertEqual(
            KnowledgeChatStore.readable("[Them · Eric Johnson]: we ship on Friday"),
            "Eric Johnson: we ship on Friday"
        )
    }

    func testEveryLineIsHandledAndBlanksCollapse() {
        let passage = """
        [Them · Eric Johnson]: we ship on Friday

        [Them · Speaker 3]: only if the auth fix lands
        [Me]: I'll take it
        """

        XCTAssertEqual(
            KnowledgeChatStore.readable(passage),
            "Eric Johnson: we ship on Friday only if the auth fix lands I'll take it"
        )
    }

    /// A tag mid-sentence is quoted speech, not a routing prefix — the old
    /// implementation replaced it anywhere in the string.
    func testATagInsideALineIsLeftAlone() {
        XCTAssertEqual(
            KnowledgeChatStore.readable("the transcript says [Them] for the other side"),
            "the transcript says [Them] for the other side"
        )
    }

    func testTextWithoutTagsIsUnchanged() {
        XCTAssertEqual(KnowledgeChatStore.readable("no tags here"), "no tags here")
    }
}
