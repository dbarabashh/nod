import XCTest
@testable import Nod

/// The quote check is the whole of the client's half of the contract: the model
/// proposes a finding, and it only reaches the user if the sentence it claims to
/// come from is literally in the window.
final class LiveMeetingAnalystTests: XCTestCase {
    private let window = """
    [Them]: okay so on pricing, I think we hold at forty for now
    [Me]: fine — I'll send the updated deck before Friday
    [Them]: and let's park the enterprise tier until we hear from legal
    """

    func testVerbatimQuoteIsAccepted() {
        XCTAssertTrue(LiveMeetingAnalyst.isQuoted("I'll send the updated deck before Friday", in: window))
    }

    func testQuoteIsAcceptedAcrossWhitespaceAndCase() {
        XCTAssertTrue(LiveMeetingAnalyst.isQuoted("I'll   send the UPDATED\n deck before Friday", in: window))
    }

    func testParaphraseIsRejected() {
        XCTAssertFalse(LiveMeetingAnalyst.isQuoted("I will send the updated deck by Friday", in: window))
    }

    func testInventedQuoteIsRejected() {
        XCTAssertFalse(LiveMeetingAnalyst.isQuoted("we agreed to raise the price to fifty", in: window))
    }

    func testStitchedQuoteIsRejected() {
        // Two real spans from different turns, joined — the model's most
        // plausible-looking way of being wrong.
        XCTAssertFalse(LiveMeetingAnalyst.isQuoted("we hold at forty and let's park the enterprise tier", in: window))
    }

    func testTooShortToBeEvidenceIsRejected() {
        XCTAssertFalse(LiveMeetingAnalyst.isQuoted("on pricing", in: window))
        XCTAssertFalse(LiveMeetingAnalyst.isQuoted("", in: window))
    }

    // MARK: - One sentence, one finding

    func testTheSameSentenceReadTwiceIsTheSameEvidence() {
        XCTAssertTrue(LiveMeetingAnalyst.sameEvidence(
            "I'll send the updated deck before Friday",
            "I'll   send the UPDATED\n deck before Friday"
        ))
    }

    func testADifferentSentenceIsDifferentEvidence() {
        XCTAssertFalse(LiveMeetingAnalyst.sameEvidence(
            "I'll send the updated deck before Friday",
            "let's park the enterprise tier until we hear from legal"
        ))
    }

    func testALongerSpanFromTheSameTurnIsNotTheSameEvidence() {
        // Two commitments in one turn are two findings, and the second one's
        // span containing the first is not grounds to refuse it.
        XCTAssertFalse(LiveMeetingAnalyst.sameEvidence(
            "I'll send the updated deck",
            "I'll send the updated deck and Anna will book the room"
        ))
    }

    func testAFindingWithNoQuoteBlocksNothing() {
        XCTAssertFalse(LiveMeetingAnalyst.sameEvidence(nil, "I'll send the updated deck before Friday"))
    }

    // MARK: - Window sizing

    func testWindowCoversTheNewMaterialPlusItsLookback() {
        XCTAssertEqual(LiveMeetingAnalyst.windowSize(forNewLines: 4), 16)
        XCTAssertEqual(LiveMeetingAnalyst.windowSize(forNewLines: 14), 26)
    }

    func testWindowIsCappedSoABurstAfterSilenceStillGetsAFullRead() {
        XCTAssertEqual(LiveMeetingAnalyst.windowSize(forNewLines: 100), LiveMeetingAnalyst.windowLines)
    }
}
