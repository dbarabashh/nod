import XCTest
@testable import Nod

/// Naming a voice and being allowed to act on the name are two different bars.
///
/// The naming pass is right often enough to print above a line of transcript and
/// wrong often enough that nobody should be handed a ticket on its say-so. These
/// pin the gap, because the failure it prevents is silent: a plausible name,
/// filed against the wrong colleague, in a product they will read.
final class SpeakerAttributionTests: XCTestCase {
    func testOnlyAConfirmedIdentityMayBeActedOn() {
        for decision in [MeetingSpeaker.Decision.llm, .elimination, .roster] {
            let guessed = MeetingSpeaker(
                cluster: 1,
                personID: UUID(),
                displayName: "Anna",
                confidence: decision.confidence,
                decidedBy: decision
            )
            XCTAssertFalse(
                guessed.isActionable,
                "\(decision.rawValue) named a speaker and must not thereby assign them work"
            )
        }

        let confirmed = MeetingSpeaker(
            cluster: 1,
            personID: UUID(),
            displayName: "Anna",
            confidence: MeetingSpeaker.Decision.user.confidence,
            decidedBy: .user
        )
        XCTAssertTrue(confirmed.isActionable)
    }

    /// Certainty about which voice it is says nothing about who that is. A
    /// cluster the user confirmed by name but that resolved to no person in the
    /// directory cannot be an assignee — there is no identifier to assign to.
    func testANameWithoutAPersonIsNeverActionable() {
        let named = MeetingSpeaker(
            cluster: 2,
            personID: nil,
            displayName: "Someone from Legal",
            confidence: 1.0,
            decidedBy: .user
        )
        XCTAssertFalse(named.isActionable)
    }

    /// The pass hands back names; `elimination` is the one the model never said
    /// and arithmetic supplied. Collapsing the two would lose the only signal
    /// that separates "read the conversation" from "counted what was left".
    func testEliminationIsWorthLessThanReadingTheConversation() {
        XCTAssertLessThan(
            MeetingSpeaker.Decision.elimination.confidence,
            MeetingSpeaker.Decision.llm.confidence
        )
        XCTAssertLessThan(
            MeetingSpeaker.Decision.llm.confidence,
            MeetingSpeaker.Decision.roster.confidence
        )
    }

    func testRowsCarryTheConfidenceOfTheSignalThatNamedThem() {
        let attributions = [
            "1": SpeakerAttribution(name: "Anna", decidedBy: .llm),
            "2": SpeakerAttribution(name: "Alex", decidedBy: .elimination),
            // A cluster key the diarizer could never emit. Dropped rather than
            // written as row zero, which is what `Int(_:)` returning nil means.
            "them": SpeakerAttribution(name: "Kate", decidedBy: .llm)
        ]
        let rows = attributions.rows()

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.cluster == 1 }?.confidence, MeetingSpeaker.Decision.llm.confidence)
        XCTAssertEqual(rows.first { $0.cluster == 2 }?.decidedBy, .elimination)
        XCTAssertNil(rows.first { $0.cluster == 1 }?.personID)
    }

    func testNamesDropsTheProvenanceForTheViewsThatOnlyDrawALabel() {
        let attributions = [
            "1": SpeakerAttribution(name: "Anna", decidedBy: .llm),
            "2": SpeakerAttribution(name: "Alex", decidedBy: .elimination)
        ]
        XCTAssertEqual(attributions.names, ["1": "Anna", "2": "Alex"])
    }
}
