import XCTest
@testable import Nod

/// A Linear issue going Done used to tick the box outright: the promise left the
/// list, nobody had looked at it, and nothing recorded why it went. The work
/// being finished and the person who was owed it knowing are different facts,
/// and only the second closes a loop.
final class LoopClosureTests: XCTestCase {
    func testATrackerCanCarryALoopButNotCloseIt() {
        XCTAssertEqual(LoopClosure.state(forTrackerClosed: true), .probablyDone)
        XCTAssertNotEqual(LoopClosure.state(forTrackerClosed: true), .confirmed)
    }

    /// Reopening is symmetric: a tracker saying a thing is open again answers
    /// the same question it answered before, and believing it costs nothing.
    func testReopeningIsBelievedImmediately() {
        XCTAssertEqual(LoopClosure.state(forTrackerClosed: false), .open)
    }

    func testClosureAndAbandonmentBothNeedAPerson() {
        XCTAssertFalse(LoopClosure.mayInfer(.confirmed))
        XCTAssertFalse(LoopClosure.mayInfer(.cancelled))
    }

    /// Everything short of closure may be inferred. Raising a loop wrongly costs
    /// a glance; the asymmetry is the whole policy.
    func testEverythingShortOfClosureMayBeInferred() {
        for state in [ActionItem.LoopState.open, .inProgress, .probablyDone, .blocked, .superseded] {
            XCTAssertTrue(LoopClosure.mayInfer(state), state.rawValue)
        }
    }

    /// `probablyDone` still wants a glance, so it must not drop out of the list
    /// the way a closed loop does.
    func testWhatATrackerClosedIsStillOpenToThePerson() {
        XCTAssertTrue(ActionItem.LoopState.probablyDone.isOpen)
        XCTAssertFalse(ActionItem.LoopState.confirmed.isOpen)
    }

    func testEveryStateIsEitherOpenOrSettledAndSaysWhich() {
        let open = ActionItem.LoopState.allCases.filter(\.isOpen).map(\.rawValue)
        let settled = ActionItem.LoopState.allCases.filter { !$0.isOpen }.map(\.rawValue)

        XCTAssertEqual(open.sorted(), ["blocked", "in_progress", "open", "probably_done"])
        XCTAssertEqual(settled.sorted(), ["cancelled", "confirmed", "superseded"])
    }

    /// The wire values are the database's check constraint. A rename here that
    /// the migration has not heard of writes rows Postgres rejects.
    func testWireValuesMatchTheDatabase() {
        XCTAssertEqual(ActionItem.LoopState.inProgress.rawValue, "in_progress")
        XCTAssertEqual(ActionItem.LoopState.probablyDone.rawValue, "probably_done")
    }

    func testATransitionCarriesWhatMovedItAndWhy() throws {
        let transition = ActionItemTransition(
            actionItemID: UUID(),
            userID: UUID(),
            fromState: .open,
            toState: .probablyDone,
            actor: .external,
            reason: "NOD-85 is closed in linear",
            evidence: [.init(provider: "linear", key: "NOD-85", url: "https://…", meetingID: nil, idx: nil)],
            confidence: 0.8,
            resolver: ActionItemStore.trackerResolver
        )
        let wire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(transition)) as? [String: Any]
        )

        XCTAssertEqual(wire["from_state"] as? String, "open")
        XCTAssertEqual(wire["to_state"] as? String, "probably_done")
        XCTAssertEqual(wire["actor"] as? String, "external")
        XCTAssertEqual((wire["evidence"] as? [[String: Any]])?.first?["key"] as? String, "NOD-85")
        XCTAssertNotNil(wire["resolver"])
    }
}

/// A state nobody can see the basis for is a state nobody can correct. The row
/// caption is what makes the loops screen arguable rather than a checklist, so
/// these pin what it says and — as importantly — when it says nothing.
final class LoopCaptionTests: XCTestCase {
    private func transition(
        actor: ActionItemTransition.Actor,
        reason: String? = nil,
        evidence: [ActionItemTransition.Evidence] = []
    ) -> ActionItemTransition {
        ActionItemTransition(
            actionItemID: UUID(),
            userID: UUID(),
            fromState: .open,
            toState: .probablyDone,
            actor: actor,
            reason: reason,
            evidence: evidence
        )
    }

    /// A quote is checkable and a paraphrase is not, so the words win whenever
    /// there are any.
    func testTheWordsThatMovedItAreTheCaption() {
        let said = transition(actor: .system, reason: "\"I sent the deck on Friday\"")

        XCTAssertEqual(said.caption, "\"I sent the deck on Friday\"")
    }

    func testATrackerFallsBackToNamingItself() {
        let linear = transition(
            actor: .external,
            evidence: [.init(provider: "linear", key: "NOD-85", url: nil, meetingID: nil, idx: nil)]
        )

        XCTAssertEqual(linear.caption, "linear says so")
    }

    func testAnInferenceWithNoQuoteStillSaysWhereItCameFrom() {
        XCTAssertEqual(transition(actor: .system).caption, "worked out from a later meeting")
    }

    /// A row that explains what the reader just did is noise.
    func testThePersonsOwnMoveCarriesNoCaption() {
        XCTAssertNil(transition(actor: .user).caption)
        // Even when one was recorded: the store never shows these, and the type
        // should not depend on the store remembering that.
        XCTAssertNil(transition(actor: .user, reason: "ticked it").caption)
    }

    func testBlankReasonsDoNotBecomeAnEmptyLine() {
        XCTAssertEqual(transition(actor: .system, reason: "   ").caption, "worked out from a later meeting")
        XCTAssertNil(transition(actor: .external, reason: "").caption)
    }

    /// How long a loop has been open is what the live pass puts on its card,
    /// so it has to be whole days, floored, and never negative — a row stamped
    /// by a server clock a second ahead must read as "today", not "-0 days".
    func testAgeIsWholeDaysAndNeverNegative() {
        let now = Date(timeIntervalSince1970: 1_787_773_380)

        XCTAssertEqual(aged(now.addingTimeInterval(-3 * 86_400)).daysOpen(to: now), 3)
        XCTAssertEqual(aged(now.addingTimeInterval(-3_600)).daysOpen(to: now), 0)
        XCTAssertEqual(aged(now.addingTimeInterval(120)).daysOpen(to: now), 0)
        XCTAssertEqual(aged(nil).daysOpen(to: now), 0)
    }

    private func aged(_ createdAt: Date?) -> ActionItem {
        ActionItem(
            id: UUID(),
            meetingID: UUID(),
            userID: UUID(),
            text: "a promise",
            deadline: nil,
            position: nil,
            done: false,
            doneAt: nil,
            externalProvider: nil,
            externalKey: nil,
            externalURL: nil,
            externalCreatedAt: nil,
            createdAt: createdAt,
            updatedAt: nil,
            deletedAt: nil
        )
    }
}
