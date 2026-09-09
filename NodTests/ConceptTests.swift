import XCTest
@testable import Nod

final class ConceptTests: XCTestCase {
    private func concept(validFrom: String?) -> RetrievedConcept {
        RetrievedConcept(
            id: UUID(),
            entityID: UUID(),
            kind: "decision",
            claimKey: "pricing",
            body: "Pricing stays at $49",
            validFromRaw: validFrom,
            meetingID: UUID(),
            provider: nil,
            externalKey: nil,
            similarity: 0.8
        )
    }

    func testParsesPostgresTimestampWithFractionalSeconds() {
        XCTAssertNotNil(concept(validFrom: "2026-08-12T09:30:15.123456Z").validFrom)
    }

    func testParsesPlainISOTimestamp() {
        XCTAssertNotNil(concept(validFrom: "2026-08-12T09:30:15Z").validFrom)
    }

    func testUnparsableTimestampYieldsNoDateInsteadOfCrashing() {
        XCTAssertNil(concept(validFrom: "not a date").validFrom)
        XCTAssertNil(concept(validFrom: nil).validFrom)
    }

    func testChangedCountsEverythingButNoops() {
        let counts = DistillCounts(added: 2, updated: 1, retired: 1, noop: 9)
        XCTAssertEqual(counts.changed, 4)
    }

    func testAllNoopSessionChangesNothing() {
        XCTAssertEqual(DistillCounts(added: 0, updated: 0, retired: 0, noop: 5).changed, 0)
    }

    func testKnowledgeSummaryReadsAsOneLine() {
        let line = NotchRecapCard.knowledgeSummary(DistillCounts(added: 2, updated: 1, retired: 0, noop: 3))
        XCTAssertEqual(line, "2 facts learned · 1 updated")
    }

    func testKnowledgeSummarySingularFact() {
        let line = NotchRecapCard.knowledgeSummary(DistillCounts(added: 1, updated: 0, retired: 1, noop: 0))
        XCTAssertEqual(line, "1 fact learned · 1 retired")
    }

    func testReplacementOfferNeedsContradictionConceptAndText() {
        let offered = LiveRecall(
            kind: .contradiction,
            text: "Pricing moved to $59",
            sourceMeetingID: UUID(),
            sourceLabel: "Board sync · Aug 26",
            conceptID: UUID(),
            replacement: "Pricing is back at $49 for everyone"
        )
        XCTAssertTrue(offered.offersReplacement)

        let notAContradiction = LiveRecall(
            kind: .decision,
            text: "x",
            sourceMeetingID: UUID(),
            sourceLabel: "y",
            conceptID: UUID(),
            replacement: "z"
        )
        XCTAssertFalse(notAContradiction.offersReplacement)

        let noConcept = LiveRecall(
            kind: .contradiction,
            text: "x",
            sourceMeetingID: UUID(),
            sourceLabel: "y",
            replacement: "z"
        )
        XCTAssertFalse(noConcept.offersReplacement)

        let emptyReplacement = LiveRecall(
            kind: .contradiction,
            text: "x",
            sourceMeetingID: UUID(),
            sourceLabel: "y",
            conceptID: UUID(),
            replacement: "  "
        )
        XCTAssertFalse(emptyReplacement.offersReplacement)
    }
}
