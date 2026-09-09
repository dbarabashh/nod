import XCTest
@testable import Nod

/// Applying the settlement model's verdicts.
///
/// Arithmetic over numbers a model chose, which is the shape every way of
/// losing a finding has taken so far. Both indexes are 1-based into the two
/// lists the prompt numbered, and anything that does not resolve leaves the
/// finding alone — the same fail-open the call takes on an error.
final class LiveFindingSettlementTests: XCTestCase {
    private func finding(_ text: String, revisionOf: UUID? = nil) -> LiveFinding {
        LiveFinding(kind: .action, text: text, revisionOf: revisionOf)
    }

    private func verdict(_ heard: Int, _ name: String, _ open: Int?) -> PromptLibrary.FindingVerdict {
        PromptLibrary.FindingVerdict(heard: heard, verdict: name, open: open)
    }

    private func settle(
        _ fresh: [LiveFinding],
        standing: [LiveFinding],
        _ verdicts: [PromptLibrary.FindingVerdict]
    ) -> [LiveFinding] {
        LiveMeetingAnalyst.settle(
            fresh,
            asking: fresh.filter { $0.revisionOf == nil },
            standing: standing,
            by: verdicts
        )
    }

    func testARepeatIsDropped() {
        let fresh = [finding("Look at the founder's twitter.")]
        let standing = [finding("The founder's twitter should be looked at.")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "repeat", 1)]), [])
    }

    func testAChangeIsKeptAndLinked() {
        let fresh = [finding("Send Anna the pricing deck by Monday")]
        let standing = [finding("Send Anna the pricing deck by Friday")]
        let settled = settle(fresh, standing: standing, [verdict(1, "change", 1)])
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.revisionOf, standing[0].id)
        XCTAssertEqual(settled.first?.id, fresh[0].id)
    }

    func testSomethingNewSurvivesUntouched() {
        let fresh = [finding("Book the offsite room in Lisbon")]
        let standing = [finding("Send Anna the pricing deck by Friday")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "new", nil)]), fresh)
    }

    // MARK: - What the model can get wrong

    func testAVerdictNamingNothingLeavesTheFindingAlone() {
        let fresh = [finding("Book the offsite room")]
        let standing = [finding("Send Anna the deck")]
        for stray in [verdict(1, "repeat", nil), verdict(1, "repeat", 0), verdict(1, "change", 9)] {
            XCTAssertEqual(settle(fresh, standing: standing, [stray]), fresh, "\(stray.verdict) \(stray.open ?? -1)")
        }
    }

    func testAVerdictAboutAnItemThatIsNotThereIsIgnored() {
        let fresh = [finding("Book the offsite room")]
        let standing = [finding("Send Anna the deck")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(2, "repeat", 1), verdict(0, "repeat", 1)]), fresh)
    }

    func testAnItemThatRepeatsTheOneBesideItIsDropped() {
        // Two items in one response saying the same thing. Neither is in
        // [ALREADY OPEN] — the response has not been committed yet — so the
        // model marks the later one a repeat of nothing.
        let fresh = [finding("Anna will introduce us to the design community"), finding("Anna is going to intro us")]
        let settled = settle(fresh, standing: [finding("Send the deck")], [verdict(2, "repeat", nil)])
        XCTAssertEqual(settled.map(\.text), ["Anna will introduce us to the design community"])
    }

    func testTheLastSurvivorIsNeverDroppedAsItsOwnTwin() {
        let fresh = [finding("Anna will introduce us to the design community")]
        XCTAssertEqual(settle(fresh, standing: [finding("Send the deck")], [verdict(1, "repeat", nil)]), fresh)
    }

    func testEitherTwinMayBeTheOneDropped() {
        // Which of two identical items the model numbers is its own choice, so
        // refusing the drop when it names the first is refusing it half the
        // time — and both duplicates then ship.
        let fresh = [finding("Anna is going to intro us"), finding("Anna will introduce us to the design community")]
        let settled = settle(fresh, standing: [finding("Send the deck")], [verdict(1, "repeat", nil)])
        XCTAssertEqual(settled.map(\.text), ["Anna will introduce us to the design community"])
    }

    func testAStrayRepeatDoesNotDropTheOnlyItemBeingJudged() {
        // A response holding a declared revision and one genuine commitment.
        // The revision is not up for judgement, so the commitment is alone —
        // and a stray "repeats one beside it" has nothing to repeat.
        let original = finding("Send Anna the deck by Friday")
        let fresh = [
            finding("Send Anna the deck by Monday", revisionOf: original.id),
            finding("Book the offsite room in Lisbon")
        ]
        let settled = settle(fresh, standing: [original], [verdict(1, "repeat", nil)])
        XCTAssertEqual(settled.count, 2)
    }

    func testAChangeNeverCrossesKinds() {
        // "Migrate the schema to Postgres" is not a change to the decision to
        // go with Postgres. Honouring it retires the decision, and the meeting
        // loses it from the record entirely.
        let decision = LiveFinding(kind: .decision, text: "We're going with Postgres")
        let task = LiveFinding(kind: .action, text: "Migrate the schema to Postgres this week")
        let settled = settle([task], standing: [decision], [verdict(1, "change", 1)])
        XCTAssertEqual(settled.count, 1)
        XCTAssertNil(settled.first?.revisionOf)
    }

    func testATwinOfAnotherKindIsNotATwin() {
        // The sibling rule, on the one path the guard above the switch cannot
        // reach: the model names no [ALREADY OPEN] entry, so the only thing to
        // compare against is the item beside it.
        let task = LiveFinding(kind: .action, text: "Book thirty minutes with legal on Thursday")
        let followUp = LiveFinding(kind: .followUp, text: "Talk to legal before we sign")
        XCTAssertEqual(
            settle([task, followUp], standing: [], [verdict(1, "repeat", nil)]),
            [task, followUp]
        )
    }

    func testAFirstPassStillSettlesTwoReadingsOfOneCommitment() {
        // Nothing open yet, so nothing to compare against but each other.
        let first = LiveFinding(kind: .action, text: "Anna will introduce us to the design community")
        let second = LiveFinding(kind: .action, text: "Anna is going to intro us")
        XCTAssertEqual(settle([first, second], standing: [], [verdict(2, "repeat", nil)]), [first])
    }

    func testARepeatNeverCrossesKindsEither() {
        // The destructive verdict, and the one a rejected cross-kind
        // `supersedes` claim now falls through to. A dated commitment read as a
        // repeat of the vague follow-up behind it is deleted outright.
        let followUp = LiveFinding(kind: .followUp, text: "Talk to legal before we sign")
        let task = LiveFinding(kind: .action, text: "Book thirty minutes with legal on Thursday")
        XCTAssertEqual(settle([task], standing: [followUp], [verdict(1, "repeat", 1)]), [task])
    }

    func testTheFirstVerdictAboutAnItemWins() {
        // Two verdicts about one item: a later "change" must not bring back
        // what an earlier "repeat" dropped, cooldown-skipping and all.
        let fresh = [finding("Look at the founder's twitter.")]
        let standing = [finding("The founder's twitter should be looked at."), finding("Send Anna the deck")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "repeat", 1), verdict(1, "change", 2)]), [])
    }

    func testAVerdictThatResolvesToNothingStillSettlesTheItem() {
        // A "new" first, a "repeat" second, about the same item. The later one
        // must not undo the earlier — the model contradicting itself is not a
        // reason to drop a finding.
        let fresh = [finding("Book the offsite room")]
        let standing = [finding("Sort out the offsite")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "new", nil), verdict(1, "repeat", 1)]), fresh)
    }

    func testOneOriginalIsRevisedOnce() {
        // Both items pointed at the same standing finding. Honouring both would
        // put two "X became Y" lines in the recap for one change of mind.
        let fresh = [finding("Send Anna the deck by Monday"), finding("Send Anna the deck by Tuesday")]
        let standing = [finding("Send Anna the deck by Friday")]
        let settled = settle(fresh, standing: standing, [verdict(1, "change", 1), verdict(2, "change", 1)])
        XCTAssertEqual(settled.map(\.revisionOf), [standing[0].id, nil])
    }

    func testAnOriginalTheLivePassAlreadyRevisedIsNotRevisedAgain() {
        let original = finding("Send Anna the deck by Friday")
        let fresh = [finding("Send Anna the deck by Monday", revisionOf: original.id), finding("Send Anna the deck")]
        let settled = settle(fresh, standing: [original], [verdict(1, "change", 1)])
        // The one the pass declared is not asked about, so verdict 1 is about
        // the *other* item — and the original is already spoken for.
        XCTAssertEqual(settled.count, 2)
        XCTAssertNil(settled.last?.revisionOf)
    }

    func testCasingDoesNotSilentlyDisableTheVerdict() {
        let fresh = [finding("Look at the founder's twitter.")]
        let standing = [finding("The founder's twitter should be looked at.")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "Repeat", 1)]), [])
    }

    func testAnUnknownVerdictKeepsTheFinding() {
        let fresh = [finding("Book the offsite room")]
        let standing = [finding("Send Anna the deck")]
        XCTAssertEqual(settle(fresh, standing: standing, [verdict(1, "maybe", 1)]), fresh)
    }

    func testNoVerdictsAtAllKeepsEverything() {
        let fresh = [finding("Book the offsite room"), finding("Send Anna the deck by Monday")]
        XCTAssertEqual(settle(fresh, standing: [finding("Send Anna the deck by Friday")], []), fresh)
    }

    func testOrderIsPreserved() {
        let fresh = [finding("Book the offsite room"), finding("Cancel the catering"), finding("Send Anna the deck")]
        let standing = [finding("Sort out the catering")]
        let settled = settle(fresh, standing: standing, [verdict(2, "repeat", 1)])
        XCTAssertEqual(settled.map(\.text), ["Book the offsite room", "Send Anna the deck"])
    }
}
