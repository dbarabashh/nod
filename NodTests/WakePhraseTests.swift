import XCTest
@testable import Nod

/// The matcher reads speech, not writing. Every case here is a shape a
/// transcriber actually produces — punctuation it invents, capitalisation it
/// guesses, and the name it mishears.
final class WakePhraseTests: XCTestCase {
    func testPlainAddress() {
        XCTAssertEqual(
            WakePhrase.request(in: "Hey Nod, what's the status of the onboarding epic"),
            "what's the status of the onboarding epic"
        )
    }

    /// Whisper punctuates the address as its own sentence about as often as not.
    func testAddressPunctuatedAsItsOwnSentence() {
        XCTAssertEqual(
            WakePhrase.request(in: "Hey, Nod. Read the pricing channel."),
            "Read the pricing channel."
        )
    }

    /// The one mishearing that matters, because "not" is a real word the model
    /// will always reach for first.
    func testMisheardName() {
        XCTAssertEqual(WakePhrase.request(in: "hey not whats in the backlog"), "whats in the backlog")
        XCTAssertEqual(WakePhrase.request(in: "Hey node, list the channels"), "list the channels")
    }

    /// Once people are used to it they drop the greeting.
    func testBareNameOpeningTheSentence() {
        XCTAssertEqual(WakePhrase.request(in: "Nod, when is the review"), "when is the review")
    }

    /// The reason the bare name only counts at the start. Mid-sentence it is
    /// overwhelmingly the word "not", and answering there would make the app
    /// interrupt people who were talking about something else entirely.
    func testNotMidSentenceIsNotAnAddress() {
        XCTAssertNil(WakePhrase.request(in: "I'm not sure we should ship that this week"))
        XCTAssertNil(WakePhrase.request(in: "that does not answer the question"))
    }

    /// Somebody getting the room's attention, not asking for anything.
    func testBareAddressAsksNothing() {
        XCTAssertNil(WakePhrase.request(in: "Hey Nod"))
        XCTAssertNil(WakePhrase.request(in: "Hey Nod."))
        XCTAssertTrue(WakePhrase.isAddressed("Hey Nod."))
    }

    /// The request keeps its own case and its numbers — the model is asked to
    /// find "Q3 pricing", not "q3 pricing".
    func testRequestKeepsItsCasing() {
        XCTAssertEqual(WakePhrase.request(in: "Hey Nod, find the Q3 Pricing deck"), "find the Q3 Pricing deck")
    }

    /// From a real recording: a Ukrainian speaker said "Hey Nod" and Whisper
    /// wrote "Гей, Нот" — the nearest real Ukrainian word. This is the case
    /// that shipped broken, so it is pinned verbatim.
    func testUkrainianMisheardAsNot() {
        XCTAssertEqual(
            WakePhrase.request(in: "Гей, Нот, можеш подивитися, будь ласка, мою останню зустріч із Владом, що ми обговорювали?"),
            "можеш подивитися, будь ласка, мою останню зустріч із Владом, що ми обговорювали?"
        )
    }

    /// The other half of the same widening: "нот" is an ordinary Ukrainian
    /// word, and it must stay ordinary everywhere except after a greeting.
    func testNotMidSentenceInUkrainianIsNotAnAddress() {
        XCTAssertNil(WakePhrase.request(in: "у нас немає нот для цієї партії"))
        XCTAssertNil(WakePhrase.request(in: "це не нот, а щось інше"))
    }

    func testUkrainianAddress() {
        XCTAssertEqual(
            WakePhrase.request(in: "Гей Нод, який статус по онбордингу"),
            "який статус по онбордингу"
        )
    }

    func testUnaddressedLine() {
        XCTAssertNil(WakePhrase.request(in: "so the campaign starts on Monday"))
        XCTAssertFalse(WakePhrase.isAddressed("so the campaign starts on Monday"))
    }
}
