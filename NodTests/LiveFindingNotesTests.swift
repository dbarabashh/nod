import XCTest
@testable import Nod

/// The lines the recap prompt is grounded on. The revision case is the reason
/// the block exists at all, so it is what these check hardest.
final class LiveFindingNotesTests: XCTestCase {
    func testPlainFindingReadsAsItsKind() {
        let notes = LiveFinding.notes(from: [
            LiveFinding(kind: .decision, text: "Ship the pricing change on Monday")
        ])
        XCTAssertEqual(notes, ["decision: Ship the pricing change on Monday"])
    }

    func testDeadlineIsCarried() {
        let notes = LiveFinding.notes(from: [
            LiveFinding(kind: .action, text: "Send the updated deck", deadline: "by Friday")
        ])
        XCTAssertEqual(notes, ["action: Send the updated deck (by Friday)"])
    }

    func testRevisionIsOneLineNamingBothSides() {
        var original = LiveFinding(kind: .action, text: "Ship on Thursday")
        original.state = .superseded
        let replacement = LiveFinding(kind: .action, text: "Ship on Monday", revisionOf: original.id)

        XCTAssertEqual(
            LiveFinding.notes(from: [original, replacement]),
            ["changed: \"Ship on Thursday\" became \"Ship on Monday\""]
        )
    }

    func testSupersededFindingIsDroppedWhenItsReplacementIsMissing() {
        // The replacement fell out of the window's memory depth. Reporting the
        // original alone would ground the recap on the version the meeting
        // abandoned — worse than saying nothing.
        var original = LiveFinding(kind: .action, text: "Ship on Thursday")
        original.state = .superseded
        XCTAssertTrue(LiveFinding.notes(from: [original]).isEmpty)
    }

    func testDefaultTierIsStrict() {
        XCTAssertEqual(LiveFinding(kind: .action, text: "Send the deck").tier, .strict)
    }

    func testDismissedFindingIsExcludedFromNotes() {
        var finding = LiveFinding(kind: .action, text: "Ask about the Blend pricing", tier: .soft)
        finding.state = .dismissed
        XCTAssertTrue(LiveFinding.notes(from: [finding]).isEmpty)
    }

    func testResolvedStatusForEachState() {
        XCTAssertEqual(LiveFinding(kind: .action, text: "Send the deck").resolvedStatus, .proposed)
        XCTAssertEqual(LiveFinding(kind: .decision, text: "Ship on Monday").resolvedStatus, .confirmed)

        var superseded = LiveFinding(kind: .action, text: "Ship on Thursday")
        superseded.state = .superseded
        XCTAssertEqual(superseded.resolvedStatus, .superseded)

        var dismissed = LiveFinding(kind: .action, text: "Ask about pricing", tier: .soft)
        dismissed.state = .dismissed
        XCTAssertEqual(dismissed.resolvedStatus, .dropped)
    }

    func testChainOfRevisionsReportsEachHop() {
        var first = LiveFinding(kind: .action, text: "Ship on Thursday")
        first.state = .superseded
        var second = LiveFinding(kind: .action, text: "Ship on Monday", revisionOf: first.id)
        second.state = .superseded
        let third = LiveFinding(kind: .action, text: "Ship next sprint", revisionOf: second.id)

        XCTAssertEqual(LiveFinding.notes(from: [first, second, third]), [
            "changed: \"Ship on Thursday\" became \"Ship on Monday\"",
            "changed: \"Ship on Monday\" became \"Ship next sprint\""
        ])
    }
}
