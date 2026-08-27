import XCTest
@testable import Nod

/// A card raised mid-sentence is the most expensive thing this app does to a
/// person, so the rules about what it may say are worth pinning apart from the
/// model call that produces it.
final class OpenLoopRecallTests: XCTestCase {
    private func recall(days: Int, kind: LiveRecall.Kind = .commitment) -> LiveRecall {
        LiveRecall(
            kind: kind,
            text: "you still owe Anna the deck",
            sourceMeetingID: UUID(),
            sourceLabel: "Weekly Sync · Aug 8",
            origin: .openLoop(days: days)
        )
    }

    /// The age is the reason the card is on screen at all, and it is the one
    /// thing a memory recall never has.
    func testALoopSaysHowLongItHasBeenOpen() {
        XCTAssertEqual(recall(days: 17).ageLabel, "17 days open")
        XCTAssertEqual(recall(days: 1).ageLabel, "1 day open")
    }

    /// "0 days open" reads as a bug, and a promise made this morning is not yet
    /// a finding worth interrupting anybody about.
    func testALoopRaisedTodayCarriesNoAge() {
        XCTAssertNil(recall(days: 0).ageLabel)
    }

    func testAMemoryRecallHasNoAgeAndNoLoop() {
        let remembered = LiveRecall(
            kind: .decision,
            text: "you settled on $49",
            sourceMeetingID: UUID(),
            sourceLabel: "Pricing · Aug 2"
        )

        XCTAssertNil(remembered.ageLabel)
        XCTAssertFalse(remembered.origin.isOpenLoop)
    }

    /// Taken from the loop's own kind rather than asked of a second model: the
    /// classification was made when the loop was raised, and redoing it from one
    /// sentence is how the same promise gets labelled two ways on two days.
    func testTheCardsLabelComesFromTheLoopsOwnKind() {
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .question), .unresolved)
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .decision), .decision)
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .action), .commitment)
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .theirs), .commitment)
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .followUp), .commitment)
        XCTAssertEqual(LiveMeetingAnalyst.recallKind(for: .risk), .commitment)
    }

    func testEveryLoopKindHasSomethingToSay() {
        for kind in ActionItem.Kind.allCases {
            XCTAssertFalse(LiveMeetingAnalyst.recallKind(for: kind).label.isEmpty)
        }
    }

    /// It shares the memory pass's budget rather than getting its own. Two
    /// proactive passes each politely rate-limited still add up to twice the
    /// interruptions.
    func testTheLoopPassIsCheaperToAskThanTheMemoryPass() {
        XCTAssertLessThan(LiveMeetingAnalyst.loopCandidates, LoopCandidates.maximum)
    }
}
