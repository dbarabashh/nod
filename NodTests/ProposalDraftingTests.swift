import XCTest
@testable import Nod

/// What a meeting offers to do about somebody else.
///
/// These are the tests for the one rule that cannot be recovered from once
/// broken: a proposal that names the wrong person files real work, in a real
/// tracker, against a real colleague. Everything else here can be undone by
/// pressing Dismiss.
final class ProposalDraftingTests: XCTestCase {
    private let alex = Person(
        personID: UUID(),
        displayName: "Alex Smith",
        email: "alex@acme.com",
        hasAccount: true,
        providers: ["linear"]
    )
    private let alexandra = Person(
        personID: UUID(),
        displayName: "Alexandra Chen",
        email: "alexandra@acme.com",
        hasAccount: true,
        providers: ["linear"]
    )
    /// No display name and no Nod account — a contractor picked up from the
    /// company's tracker. Assignable exactly like anybody else, which is the
    /// point of importing a workspace at all.
    private let anna = Person(
        personID: UUID(),
        displayName: nil,
        email: "anna@acme.com",
        hasAccount: false,
        providers: ["linear"]
    )

    // MARK: - Resolving a name

    func testAGivenNameResolvesToTheOnePersonWhoHasIt() throws {
        let outcome = PersonResolver.resolve("Alex", in: [alex, anna])
        XCTAssertEqual(
            outcome,
            try .resolved(personID: XCTUnwrap(alex.personID), name: "Alex Smith", confidence: PersonResolver.nameMatchConfidence)
        )
    }

    /// "Alex" against Alex Smith and Alexandra Chen. A prefix match would pick
    /// whichever sorted first and file the work in the wrong queue.
    func testAPrefixIsNotAMatch() {
        let outcome = PersonResolver.resolve("Alex", in: [alexandra])
        XCTAssertEqual(outcome, .unknown, "Alexandra is not Alex")
    }

    func testANameThatFitsTwoPeopleAsksRatherThanPicks() {
        let alexJones = Person(
            personID: UUID(),
            displayName: "Alex Jones",
            email: "aj@acme.com",
            hasAccount: true,
            providers: ["linear"]
        )
        let outcome = PersonResolver.resolve("Alex", in: [alex, alexJones])
        XCTAssertEqual(outcome, .ambiguous(names: ["Alex Jones", "Alex Smith"]))
    }

    /// Somebody with no display name is still addressable — the local part of
    /// their address is what colleagues call them in practice.
    func testTheAddressIsAName() throws {
        let outcome = PersonResolver.resolve("anna", in: [anna])
        XCTAssertEqual(
            outcome,
            try .resolved(personID: XCTUnwrap(anna.personID), name: "anna", confidence: PersonResolver.nameMatchConfidence)
        )
    }

    func testCaseAndAccentsDoNotDecideWhoSomebodyIs() {
        let renee = Person(
            personID: UUID(),
            displayName: "Renée Dubois",
            email: "renee@acme.com",
            hasAccount: true,
            providers: ["linear"]
        )
        guard case let .resolved(_, _, confidence) = PersonResolver.resolve("RENEE", in: [renee]) else {
            return XCTFail("Renée should resolve regardless of case or accent")
        }
        XCTAssertEqual(confidence, PersonResolver.nameMatchConfidence)
    }

    /// A speaker the user pointed at during the meeting beats a string match
    /// against the directory, and is the only path to full confidence.
    func testAConfirmedSpeakerOutranksANameMatch() throws {
        let confirmed = MeetingSpeaker(
            cluster: 2,
            personID: anna.personID,
            displayName: "Alex Smith",
            confidence: 1.0,
            decidedBy: .user
        )
        let outcome = PersonResolver.resolve("Alex Smith", in: [alex], confirmedSpeakers: [confirmed])
        XCTAssertEqual(
            outcome,
            try .resolved(personID: XCTUnwrap(anna.personID), name: "Alex Smith", confidence: PersonResolver.confirmedConfidence)
        )
    }

    /// A cluster the naming pass guessed is not a confirmation, however
    /// confident the name reads on screen.
    func testAGuessedSpeakerDoesNotOutrankAnything() throws {
        let guessed = MeetingSpeaker(
            cluster: 2,
            personID: anna.personID,
            displayName: "Alex Smith",
            confidence: MeetingSpeaker.Decision.llm.confidence,
            decidedBy: .llm
        )
        let outcome = PersonResolver.resolve("Alex Smith", in: [alex], confirmedSpeakers: [guessed])
        XCTAssertEqual(
            outcome,
            try .resolved(personID: XCTUnwrap(alex.personID), name: "Alex Smith", confidence: PersonResolver.nameMatchConfidence)
        )
    }

    // MARK: - Drafting

    func testACommitmentByANamedColleagueIsReadyToFile() {
        let item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Migrate the backend to OAuth",
            deadline: "by Friday",
            position: 0,
            kind: .theirs
        )
        let drafts = ProposalDrafting.drafts(
            for: [item],
            owners: [0: "Alex"],
            provider: .linear,
            directory: [alex, anna]
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].type, "linear.create_issue")
        XCTAssertEqual(drafts[0].parameters["assignee_person_id"], alex.personID.uuidString)
        XCTAssertEqual(drafts[0].parameters["description"], "Due: by Friday")
        XCTAssertEqual(drafts[0].status, .ready)
    }

    /// The rule from `18.1 Conservative execution`, as a test: an owner nobody
    /// can identify becomes no owner and a question, never a guess.
    func testAnUnresolvableOwnerIsLeftBlankAndAsked() {
        let item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Investigate the callback API",
            deadline: nil,
            position: 0,
            kind: .theirs
        )
        let drafts = ProposalDrafting.drafts(
            for: [item],
            owners: [0: "somebody from mobile"],
            provider: .linear,
            directory: [alex, anna]
        )

        XCTAssertNil(drafts[0].parameters["assignee_person_id"])
        XCTAssertEqual(drafts[0].parameters["assignee_hint"], "somebody from mobile")
        XCTAssertEqual(drafts[0].status, .needsReview)
    }

    /// The user's own to-do names nobody, so it makes no claim about an owner
    /// and must not be marked as missing one.
    func testTheUsersOwnTaskIsNotMissingAnOwner() {
        let item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Write the migration checklist",
            deadline: nil,
            position: 0
        )
        let drafts = ProposalDrafting.drafts(for: [item], owners: [:], provider: .linear, directory: [alex])

        XCTAssertEqual(drafts[0].confidence.parts[.owner], nil)
        XCTAssertEqual(drafts[0].status, .ready)
    }

    /// A live-pass finding the recap corroborated is still a weaker reading than
    /// the recap's own, and must not arrive pre-blessed as ready.
    func testALiveFindingIsNotReadyOnItsOwn() {
        var item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Book time with Legal",
            deadline: nil,
            position: 0,
            source: .live
        )
        item.source = .live
        let drafts = ProposalDrafting.drafts(for: [item], owners: [:], provider: .linear, directory: [alex])
        XCTAssertEqual(drafts[0].status, .proposed)
    }

    func testNothingIsProposedForWorkAlreadyFiledOrDoneOrBinned() throws {
        let meetingID = UUID()
        let userID = UUID()
        let base = ActionItem.new(meetingID: meetingID, userID: userID, text: "Ship it", deadline: nil, position: 0)

        let filed = try base.filed(
            in: ProviderLinkItem(provider: .linear, title: "NOD-1", url: XCTUnwrap(URL(string: "https://linear.app/x"))),
            at: Date()
        )
        let done = base.marked(done: true, at: Date())
        var proposedOnly = base
        proposedOnly.status = .proposed
        var note = base
        note.kind = .decision

        for item in [filed, done, proposedOnly, note] {
            XCTAssertTrue(
                ProposalDrafting.drafts(for: [item], owners: [:], provider: .linear, directory: []).isEmpty,
                "\(item.kind.rawValue)/\(item.status.rawValue) should not be offered again"
            )
        }
    }

    /// The calendar cannot take a task, and offering to file one there would be
    /// a proposal nothing could execute.
    func testAProviderThatTakesNoTasksProposesNothing() {
        let item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Anything",
            deadline: nil,
            position: 0
        )
        XCTAssertTrue(
            ProposalDrafting.drafts(for: [item], owners: [:], provider: .googleCalendar, directory: []).isEmpty
        )
    }

    // MARK: - Confidence

    func testTheWeakestClaimDecides() {
        var confidence = ProposalConfidence(semantic: 0.99)
        confidence.record(.owner, 0.3)
        XCTAssertEqual(confidence.overall, 0.3, accuracy: 0.0001)
        XCTAssertEqual(confidence.status, .needsReview)
    }

    /// Answering the owner question must not be dragged back down by the score
    /// that question caused. This is why the parts are stored, not just the total.
    func testNamingTheOwnerAfterwardsRestoresTheProposal() {
        var initial = ProposalConfidence(semantic: 0.95)
        initial.record(.owner, PersonResolver.ambiguousConfidence)
        XCTAssertEqual(initial.status, .needsReview)

        var answered = ProposalConfidence(stored: initial.stored)
        answered.record(.owner, PersonResolver.confirmedConfidence)
        XCTAssertEqual(answered.overall, 0.95, accuracy: 0.0001)
        XCTAssertEqual(answered.status, .ready)
    }
}
