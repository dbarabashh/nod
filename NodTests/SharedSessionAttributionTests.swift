import XCTest
@testable import Nod

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
    func testTheOwnerIsNamedWithoutAssumingReaderAttendance() {
        let text = prompt(host: "Vlad Kampov")

        XCTAssertTrue(text.contains("Vlad Kampov recorded it"))
        XCTAssertTrue(text.contains("[Me · Vlad Kampov] is Vlad Kampov"))
        XCTAssertTrue(text.contains("do not assume presence or absence"))
        XCTAssertFalse(text.contains("NOT in it"))
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

    /// The cross-session chat had the same hole for longer, and worse: it can
    /// hold a shared session and the user's own in one prompt, and it stated
    /// flatly that "[Me]" was the user. A meeting a colleague recorded came
    /// back as "you had a call with Georgi".
    func testTheKnowledgePromptReadsOwnershipOffEachLabel() {
        let text = PromptLibrary.buildKnowledgeSystem(excerpts: ["[From: Ads agency — Tuesday]\n[Me]: hello"])

        XCTAssertTrue(text.contains("recorded by <name>, shared with the user"))
        XCTAssertTrue(text.contains("sharing alone does not establish whether the user attended"))
        XCTAssertFalse(text.contains("the user was NOT there"))
        // The old flat claim is what produced the wrong answer.
        XCTAssertFalse(text.contains(#""[Me]" is the user"#))
    }

    /// The recap travels inside each grounding block in this prompt too, and
    /// carries the same second person as the per-session one.
    func testTheKnowledgePromptBindsASharedRecapsSecondPerson() {
        XCTAssertTrue(PromptLibrary.sharedSessionRule.contains("written for <name>"))
        XCTAssertTrue(PromptLibrary.sharedSessionRule.contains(#"every "you" and "your" inside it means <name>"#))
    }

    /// The same note labels a shared session's open action items, so the rule
    /// has to reach them too — a colleague's follow-up is not the reader's
    /// to-do, and it arrives through a different block.
    func testTheRuleReachesTasksFromASharedSession() {
        XCTAssertTrue(PromptLibrary.sharedSessionRule.contains("task source"))
        XCTAssertTrue(PromptLibrary.sharedSessionRule.contains("action item"))
    }

    /// The rule is only worth anything if the label actually says the words it
    /// tells the model to look for. The store writes one, the prompt describes
    /// the other, and nothing but this connects them.
    func testTheLabelNoteIsTheShapeTheRuleLooksFor() {
        let note = PromptLibrary.sharedSessionLabelNote(host: "Vlad Kampov")

        XCTAssertEqual(note, "recorded by Vlad Kampov, shared with the user")
        XCTAssertTrue(
            PromptLibrary.sharedSessionRule.contains(note.replacingOccurrences(of: "Vlad Kampov", with: "<name>"))
        )
    }

    /// The profile block is prepended to prompts that have no transcript at all,
    /// and it is the reader's own name. Binding `[Me]` to it there was the bug:
    /// which voice the tag belongs to is known where the session is.
    func testTheProfileBlockDoesNotSayWhoMeIs() {
        let block = Profile(userID: UUID(), displayName: "Dima").promptBlock

        XCTAssertTrue(block.contains("Dima"))
        XCTAssertFalse(block.contains("[Me]"))
    }

    func testBothChatsSeparateTheAccountHolderFromSourceSpeakers() {
        let prompts = [prompt(host: "Vlad Kampov"), PromptLibrary.buildKnowledgeSystem(excerpts: [])]
        for text in prompts {
            XCTAssertTrue(text.contains(PromptLibrary.chatRelationshipRules))
            XCTAssertTrue(text.contains("[WHO IS ASKING]"))
            XCTAssertTrue(text.contains("Preserve explicit assignees"))
        }
    }

    func testMentionedSessionsCarryTheirOwnOwnershipRules() {
        let text = PromptLibrary.buildChatSystem(
            sessionKind: .meeting, title: "My call", summary: "", transcript: "",
            mentionedSessions: PromptLibrary.sharedSessionLabelNote(host: "Alex")
        )
        XCTAssertTrue(text.contains(PromptLibrary.sharedSessionRule))
    }

    func testGroundingBlockPreservesSharedOwner() {
        let block = PromptLibrary.sessionGroundingBlock(
            label: "Planning", recap: "You will follow up", excerpts: [], host: "Alex"
        )
        XCTAssertTrue(block.contains("Planning — " + PromptLibrary.sharedSessionLabelNote(host: "Alex")))
    }

    @MainActor
    func testMissingDirectoryNameDoesNotBecomeTheViewer() {
        let viewer = UUID()
        let owner = UUID()
        XCTAssertNil(OrganizationService.promptOwnerName(ownerID: viewer, viewerID: viewer, name: nil))
        XCTAssertNotNil(OrganizationService.promptOwnerName(ownerID: owner, viewerID: viewer, name: nil))
        XCTAssertNotNil(OrganizationService.promptOwnerName(ownerID: owner, viewerID: nil, name: nil))
        XCTAssertEqual(OrganizationService.promptOwnerName(ownerID: owner, viewerID: viewer, name: "Alex"), "Alex")
    }
}
