import XCTest
@testable import Nod

/// A promise made in June sits open until somebody ticks it, and nobody ticks
/// it — while the July call where it was said to be done is already recorded and
/// nothing reads it. These pin the two halves that must be right for reading it
/// to be safe: which loops the model is shown, and which of its answers survive.
final class LoopResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_773_380)
    private let thisMeeting = UUID()

    private func loop(
        _ text: String,
        meeting: UUID? = nil,
        loop state: ActionItem.LoopState = .open,
        status: ActionItem.Status = .confirmed,
        daysAgo: Int = 10,
        deleted: Bool = false
    ) -> ActionItem {
        var made = ActionItem(
            id: UUID(),
            meetingID: meeting ?? UUID(),
            userID: UUID(),
            text: text,
            deadline: nil,
            position: nil,
            done: false,
            doneAt: nil,
            externalProvider: nil,
            externalKey: nil,
            externalURL: nil,
            externalCreatedAt: nil,
            createdAt: now.addingTimeInterval(-Double(daysAgo) * 86_400),
            updatedAt: nil,
            deletedAt: deleted ? now : nil
        )
        made.loopState = state
        made.status = status
        return made
    }

    private func picked(_ loops: [ActionItem], _ transcript: String, limit: Int = 30) -> [String] {
        LoopCandidates.pick(from: loops, mentionedIn: transcript, excluding: thisMeeting, limit: limit)
            .map(\.text)
    }

    // MARK: - What the model is shown

    func testOnlyLoopsTheConversationTouchedAreCarried() {
        let shown = picked(
            [loop("send the pricing deck to Acme"), loop("book the venue for the offsite")],
            "we finally sent the pricing deck this morning"
        )

        XCTAssertEqual(shown, ["send the pricing deck to Acme"])
    }

    /// Asking whether this conversation resolved what this conversation just
    /// raised is asking the model to agree with itself.
    func testThisMeetingsOwnLoopsAreNotCarried() {
        let shown = picked(
            [loop("send the pricing deck", meeting: thisMeeting)],
            "we sent the pricing deck"
        )

        XCTAssertTrue(shown.isEmpty)
    }

    func testSettledAndUncorroboratedLoopsAreNotCarried() {
        let shown = picked([
            loop("send the pricing deck", loop: .confirmed),
            loop("send the pricing deck again", loop: .cancelled),
            loop("send the pricing deck maybe", status: .proposed),
            loop("send the pricing deck once more", deleted: true)
        ], "we sent the pricing deck")

        XCTAssertTrue(shown.isEmpty)
    }

    /// The whole point is the loop that has been forgotten, so a tie broken
    /// towards the recent one quietly buries it.
    func testEqualOverlapPrefersTheOlderLoop() {
        let shown = picked([
            loop("review the migration plan", daysAgo: 2),
            loop("review the migration plan", daysAgo: 60)
        ], "we went through the migration plan review")

        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(
            LoopCandidates.pick(
                from: [loop("review the migration plan", daysAgo: 2), loop("review the migration plan", daysAgo: 60)],
                mentionedIn: "migration plan review",
                excluding: thisMeeting,
                limit: 1
            ).count,
            1
        )
    }

    func testTheListIsCappedSoThePromptStaysAPage() {
        let many = (0 ..< 100).map { loop("ship the migration piece \($0)") }

        XCTAssertEqual(picked(many, "migration shipping", limit: 30).count, 30)
    }

    func testWordsCommonToEveryMeetingSeparateNothing() {
        XCTAssertFalse(LoopCandidates.words(in: "we should make that happen").contains("should"))
        XCTAssertFalse(LoopCandidates.words(in: "нам треба буде це зробити").contains("треба"))
        XCTAssertTrue(LoopCandidates.words(in: "the migration plan").contains("migration"))
    }

    func testShortWordsAreNotEvidenceOfAnything() {
        // "the" and "it" match every transcript ever recorded.
        XCTAssertTrue(LoopCandidates.words(in: "do it").isEmpty)
    }

    // MARK: - What survives checking

    /// The model answers with numbers against the list it was shown. A number
    /// outside that list is not a loop, whatever it looks like.
    func testOnlyTheThreeAllowedVerbsBecomeStates() {
        XCTAssertEqual(LoopResolver.state(for: "done"), .probablyDone)
        XCTAssertEqual(LoopResolver.state(for: "progressed"), .inProgress)
        XCTAssertEqual(LoopResolver.state(for: "blocked"), .blocked)
        XCTAssertEqual(LoopResolver.state(for: "DONE"), .probablyDone)
    }

    /// A model that invents a verb must move nothing — above all one that would
    /// close a loop.
    func testAnInventedVerbMovesNothing() {
        for verb in ["confirmed", "cancelled", "closed", "finished", "", "✅"] {
            XCTAssertNil(LoopResolver.state(for: verb), verb)
        }
    }

    /// Somebody saying they sent a thing is good evidence and not the person who
    /// was waiting for it saying they got it.
    func testSayingItIsDoneNeverClosesTheLoop() {
        let state = try? XCTUnwrap(LoopResolver.state(for: "done"))
        XCTAssertEqual(state, .probablyDone)
        XCTAssertTrue(state?.isOpen == true)
        XCTAssertTrue(LoopClosure.mayInfer(state ?? .open))
    }

    func testTheContractIsWhatThePromptAsksFor() throws {
        let json = #"{"moved":[{"loop":2,"to":"done","said":"I sent it Friday"}]}"#
        let decoded = try JSONDecoder().decode(PromptLibrary.LoopMoves.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.moved.first?.loop, 2)
        XCTAssertEqual(decoded.moved.first?.said, "I sent it Friday")
    }

    /// Silence is the ordinary answer and must parse as cleanly as a move.
    func testMovingNothingIsAValidAnswer() throws {
        let decoded = try JSONDecoder().decode(PromptLibrary.LoopMoves.self, from: Data(#"{"moved":[]}"#.utf8))

        XCTAssertTrue(decoded.moved.isEmpty)
    }

    func testThePromptNumbersTheLoopsItAsksAbout() {
        let prompt = PromptLibrary.buildLoopResolution(
            loops: [loop("send the deck"), loop("book the venue")],
            transcript: "we sent the deck",
            meetingTitle: "Weekly",
            now: now
        )

        XCTAssertTrue(prompt.user.contains("0. send the deck"))
        XCTAssertTrue(prompt.user.contains("1. book the venue"))
        XCTAssertTrue(prompt.system.contains("Talking about a promise is not keeping it."))
    }
}
