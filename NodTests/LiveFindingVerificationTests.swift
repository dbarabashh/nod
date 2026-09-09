import XCTest
@testable import Nod

/// What the live pass is allowed to put in front of somebody mid-sentence.
///
/// The model proposes; this is the half that says no. Every case here is one
/// the model has actually produced on a real call — a sentence read twice in
/// two overlapping windows, a revision pointed at the wrong entry, a "Changed"
/// card that changed nothing.
final class LiveFindingVerificationTests: XCTestCase {
    private let window = """
    [Them]: okay so on pricing, I think we hold at forty for now
    [Me]: fine — I'll send the updated deck before Friday
    [Them]: and let's park the enterprise tier until we hear from legal
    """

    private func item(
        kind: String = "action",
        text: String,
        quote: String,
        supersedes: Int? = nil
    ) -> PromptLibrary.LivePassItem {
        PromptLibrary.LivePassItem(
            kind: kind,
            tier: "strict",
            text: text,
            deadline: nil,
            quote: quote,
            supersedes: supersedes
        )
    }

    private func verify(
        _ item: PromptLibrary.LivePassItem,
        memory: [LiveFinding] = [],
        found: [LiveFinding]? = nil,
        evidenceIdx: Int? = 1
    ) -> LiveFinding? {
        LiveMeetingAnalyst.verify(
            item,
            window: window,
            memory: memory,
            found: found ?? memory,
            evidence: (evidenceIdx, nil)
        )
    }

    private func finding(
        kind: ActionItem.Kind = .action,
        text: String,
        quote: String,
        evidenceIdx: Int? = 1,
        state: LiveFinding.State = .standing
    ) -> LiveFinding {
        LiveFinding(
            kind: kind,
            text: text,
            evidenceIdx: evidenceIdx,
            quote: quote,
            state: state
        )
    }

    // MARK: - One sentence, one finding

    func testASecondReadingOfTheSameLineIsRefused() {
        let standing = finding(
            text: "Send the updated deck before Friday",
            quote: "I'll send the updated deck before Friday"
        )
        let second = item(
            kind: "follow_up",
            text: "Talk again about the deck before Friday",
            quote: "I'll send the updated deck before Friday"
        )
        XCTAssertNil(verify(second, memory: [standing]))
    }

    func testASecondCommitmentInTheSameTurnIsKept() {
        // A transcript entry is a whole VAD segment — seventeen seconds at p90
        // — so one entry routinely carries two commitments. The first must not
        // veto the second.
        let first = finding(
            text: "Send the updated deck before Friday",
            quote: "I'll send the updated deck before Friday",
            evidenceIdx: 1
        )
        let second = item(
            kind: "decision",
            text: "Park the enterprise tier until legal answers",
            quote: "let's park the enterprise tier until we hear from legal"
        )
        XCTAssertNotNil(verify(second, memory: [first], evidenceIdx: 1))
    }

    func testTheSameWordsSaidAboutSomethingElseLaterAreANewFinding() {
        // "I'll send it over" is said about the deck at minute six and about
        // the SOC 2 letter at minute forty-eight. Two lines, two findings.
        let earlier = finding(
            text: "Send the pricing deck to Anna",
            quote: "I'll send the updated deck before Friday",
            evidenceIdx: 1
        )
        let later = item(
            text: "Send the SOC 2 letter to Anna",
            quote: "I'll send the updated deck before Friday"
        )
        XCTAssertNotNil(verify(later, memory: [earlier], evidenceIdx: 48))
    }

    func testAVetoedReadingDoesNotBlockALaterGenuineOne() {
        // The user's dismiss is a no to that reading of the sentence, not to
        // the sentence — the memory is built on that rule and this guard has
        // to keep it.
        let vetoed = finding(
            text: "Send the updated deck before Friday",
            quote: "I'll send the updated deck before Friday",
            state: .dismissed
        )
        let genuine = item(
            kind: "decision",
            text: "The deck goes out before Friday",
            quote: "I'll send the updated deck before Friday"
        )
        XCTAssertNotNil(verify(genuine, memory: [], found: [vetoed]))
    }

    // MARK: - Revisions

    func testAChangeOfMindIsKept() {
        let original = finding(
            text: "Hold pricing at forty for now",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let revision = item(
            text: "Hold pricing at forty until legal answers",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        let verified = verify(revision, memory: [original], evidenceIdx: 2)
        XCTAssertEqual(verified?.revisionOf, original.id)
    }

    func testAOneWordChangeIsARevisionAndNotARestatement() {
        // The three changes [SUPERSEDES] names: a new date, a different owner,
        // a reversal. Each leaves most of the sentence intact, so a similarity
        // bar catches them as re-emissions and throws the change of mind away.
        let cases = [
            ("Send Anna the pricing deck by Friday", "Send Anna the pricing deck by Monday"),
            ("Anna sends the pricing deck by Friday", "Mike sends the pricing deck by Friday"),
            ("Book the offsite room for June", "Cancel the offsite room for June")
        ]
        for (before, after) in cases {
            let original = finding(
                text: before,
                quote: "I think we hold at forty for now",
                evidenceIdx: 0
            )
            let revision = item(
                text: after,
                quote: "let's park the enterprise tier until we hear from legal",
                supersedes: 1
            )
            let verified = verify(revision, memory: [original], evidenceIdx: 2)
            XCTAssertEqual(verified?.revisionOf, original.id, "\(before) → \(after)")
        }
    }

    func testAChangeToADigitOrAShortWordIsStillARevision() {
        // Where a change of mind actually lives. The meaningful-token filter
        // drops anything under three characters, so on tokens alone each of
        // these pairs is identical and the room's correction is thrown away.
        let cases = [
            ("Ship v2 by Friday", "Ship v3 by Friday"),
            ("Hold pricing at 40 for now", "Hold pricing at 50 for now"),
            ("Email Jo the pricing deck", "Email Al the pricing deck")
        ]
        for (before, after) in cases {
            let original = finding(text: before, quote: "I think we hold at forty for now", evidenceIdx: 0)
            let revision = item(
                text: after,
                quote: "let's park the enterprise tier until we hear from legal",
                supersedes: 1
            )
            let verified = verify(revision, memory: [original], evidenceIdx: 2)
            XCTAssertEqual(verified?.revisionOf, original.id, "\(before) → \(after)")
        }
    }

    func testARevisionWideningTowardsASiblingIsKept() {
        // Two tasks that legitimately stand side by side, and a merge of them.
        // Judged by similarity the merge reads as the sibling and is thrown
        // away with the change of mind inside it.
        let anna = finding(text: "Send the deck to Anna", quote: "I think we hold at forty for now", evidenceIdx: 0)
        let mike = finding(
            text: "Send the deck to Mike",
            quote: "I'll send the updated deck before Friday",
            evidenceIdx: 1
        )
        let merged = item(
            text: "Send the deck to Anna and Mike",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        let verified = verify(merged, memory: [anna, mike], evidenceIdx: 2)
        XCTAssertEqual(verified?.revisionOf, anna.id)
    }

    func testARevisionQuotingTheLineItRevisesIsRefused() {
        let original = finding(
            text: "Hold pricing at forty for now",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let reread = item(
            text: "Keep the price at forty until further notice",
            quote: "I think we hold at forty for now",
            supersedes: 1
        )
        XCTAssertNil(verify(reread, memory: [original], evidenceIdx: 0))
    }

    func testAnOriginalSomethingElseIsAlreadyRevisingIsNotRevisedAgain() {
        // Two items in one response both point at entry 1. The retirement does
        // not land until the whole response is verified, so the original still
        // reads as standing — what stops the second is that the first is
        // already revising it.
        let original = finding(
            text: "Send the updated deck before Friday",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let first = LiveFinding(
            kind: .action,
            text: "Send the updated deck before Monday",
            quote: "I'll send the updated deck before Friday",
            revisionOf: original.id
        )
        let second = item(
            text: "Send the updated deck before Tuesday instead",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        let verified = verify(second, memory: [original], found: [original, first], evidenceIdx: 2)
        XCTAssertNotNil(verified)
        XCTAssertNil(verified?.revisionOf)
    }

    func testAnOutOfRangeClaimIsReadAsANewFinding() {
        let original = finding(
            text: "Hold pricing at forty for now",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        for claim in [0, 2, -1] {
            let stray = item(
                text: "Hold pricing at forty until legal answers",
                quote: "let's park the enterprise tier until we hear from legal",
                supersedes: claim
            )
            let verified = verify(stray, memory: [original], evidenceIdx: 2)
            XCTAssertNotNil(verified, "supersedes: \(claim)")
            XCTAssertNil(verified?.revisionOf, "supersedes: \(claim)")
        }
    }

    func testARevisionRepeatingItsOriginalWordForWordIsRefused() {
        let original = finding(
            text: "Send the updated deck before Friday",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let echo = item(
            text: "  send the UPDATED deck before friday ",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        XCTAssertNil(verify(echo, memory: [original], evidenceIdx: 2))
    }

    func testANameSwapIsARevisionAndNotARepeat() {
        // The same words in a different order, and the whole point of the
        // sentence. Anything that compares words as a set — which is every
        // similarity measure here — reads this as the original said twice.
        let original = finding(
            text: "Anna sends the deck to Mike",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let swapped = item(
            text: "Mike sends the deck to Anna",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        XCTAssertEqual(verify(swapped, memory: [original], evidenceIdx: 2)?.revisionOf, original.id)
    }

    // MARK: - The model's half of the contract

    func testAnInventedQuoteCostsTheItem() {
        XCTAssertNil(verify(item(text: "Raise the price to fifty", quote: "we agreed to raise the price to fifty")))
    }

    func testAKindThisBuildHasNoCaseForIsRefused() {
        XCTAssertNil(verify(item(kind: "vibe", text: "Everyone felt good", quote: "we hold at forty for now")))
    }

    func testAnEmptyTextIsRefused() {
        XCTAssertNil(verify(item(text: "   ", quote: "we hold at forty for now")))
    }

    func testACorrectionPastTheEndOfTheModelsMemoryIsKept() {
        // The memory handed to the model is the last dozen findings. A finding
        // older than that cannot be pointed at with `supersedes`, so its
        // correction necessarily arrives unflagged — and no similarity bar can
        // tell that apart from a repeat. Comparing against it anyway is how the
        // room's change of mind gets eaten.
        let old = finding(
            text: "Send Anna the updated pricing deck by Friday",
            quote: "I think we hold at forty for now",
            evidenceIdx: 0
        )
        let correction = item(
            text: "Send Anna the updated pricing deck by Monday",
            quote: "let's park the enterprise tier until we hear from legal"
        )
        XCTAssertNotNil(verify(correction, memory: [], found: [old], evidenceIdx: 2))
    }

    // MARK: - What is worth interrupting for

    func testAQuestionIsNeverWorthInterruptingUnlessThePassCalledItAChange() {
        let question = LiveFinding(kind: .question, text: "We still don't know what legal says")
        XCTAssertFalse(LiveMeetingAnalyst.worthInterrupting(question, urgent: false))
        XCTAssertTrue(LiveMeetingAnalyst.worthInterrupting(question, urgent: true))
    }

    func testACommitmentOrADecisionEarnsOneOnItsOwn() {
        for kind in [ActionItem.Kind.action, .decision] {
            XCTAssertTrue(
                LiveMeetingAnalyst.worthInterrupting(LiveFinding(kind: kind, text: "Send the deck"), urgent: false),
                kind.rawValue
            )
        }
        for kind in [ActionItem.Kind.risk, .followUp] {
            XCTAssertFalse(
                LiveMeetingAnalyst.worthInterrupting(LiveFinding(kind: kind, text: "Send the deck"), urgent: false),
                kind.rawValue
            )
        }
    }

    func testARevisionClaimNeverCrossesKinds() {
        // A task carrying out a decision does not replace it. Honouring the
        // claim retires the decision, and the meeting loses it from the record.
        let decision = LiveFinding(
            kind: .decision,
            text: "We're going with Postgres",
            evidenceIdx: 0,
            quote: "I think we hold at forty for now"
        )
        let task = item(
            text: "Migrate the schema to Postgres this week",
            quote: "let's park the enterprise tier until we hear from legal",
            supersedes: 1
        )
        let verified = verify(task, memory: [decision], evidenceIdx: 2)
        XCTAssertNotNil(verified)
        XCTAssertNil(verified?.revisionOf)
    }
}
