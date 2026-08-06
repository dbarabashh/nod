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
        original.isSuperseded = true
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
        original.isSuperseded = true
        XCTAssertTrue(LiveFinding.notes(from: [original]).isEmpty)
    }

    func testChainOfRevisionsReportsEachHop() {
        var first = LiveFinding(kind: .action, text: "Ship on Thursday")
        first.isSuperseded = true
        var second = LiveFinding(kind: .action, text: "Ship on Monday", revisionOf: first.id)
        second.isSuperseded = true
        let third = LiveFinding(kind: .action, text: "Ship next sprint", revisionOf: second.id)

        XCTAssertEqual(LiveFinding.notes(from: [first, second, third]), [
            "changed: \"Ship on Thursday\" became \"Ship on Monday\"",
            "changed: \"Ship on Monday\" became \"Ship next sprint\""
        ])
    }
}
