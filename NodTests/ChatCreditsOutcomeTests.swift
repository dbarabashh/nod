import XCTest
@testable import Nod

/// A read refused for want of credits is a bill, not a broken integration.
/// These pin that the server's code — not its prose — is what the chats and
/// the notch key on, so a reworded message never turns the notice back into
/// a truncated warning.
@MainActor
final class ChatCreditsOutcomeTests: XCTestCase {
    private let exhausted = #"{"error":{"code":"integration_credits_exhausted","message":"This period's integration credits are used up. Answer with what you already know."}}"#

    func testExhaustedCreditsAreTheirOwnOutcome() {
        XCTAssertEqual(ChatToolGate.outcome(of: exhausted), .outOfCredits)
    }

    func testAnyOtherErrorStaysAFailureWithItsMessage() {
        let result = #"{"error":{"code":"not_connected","message":"Linear is not connected."}}"#
        XCTAssertEqual(ChatToolGate.outcome(of: result), .failed("Linear is not connected."))
    }

    func testAResultWithoutAnErrorRan() {
        XCTAssertEqual(ChatToolGate.outcome(of: #"{"result":{"issues":[]}}"#), .ran)
    }

    func testTheCodeIsReadFromTheEnvelope() {
        XCTAssertEqual(IntegrationService.failureCode(in: exhausted), IntegrationService.creditsExhaustedCode)
        XCTAssertNil(IntegrationService.failureCode(in: #"{"result":1}"#))
        XCTAssertNil(IntegrationService.failureCode(in: "not json"))
    }

    func testATurnKnowsWhenItRanOutOfCredits() {
        let ran = ChatTurnStep(provider: .linear, action: "search_issues", detail: "", outcome: .ran)
        let unpaid = ChatTurnStep(provider: .linear, action: "read_issues", detail: "", outcome: .outOfCredits)
        XCTAssertFalse([ran].ranOutOfCredits)
        XCTAssertTrue([ran, unpaid].ranOutOfCredits)
        XCTAssertFalse([ChatTurnStep]().ranOutOfCredits)
    }

    func testTheNotchNamesTheBillNotTheProduct() {
        let label = LiveLookup.Failure.outOfCredits.label
        XCTAssertTrue(label.contains("credits"), label)
        XCTAssertFalse(label.contains("reach"), label)
        XCTAssertFalse(label.contains("pack"), label)
    }

    func testAnInactivePlanIsRefusedWithTheSameCode() {
        let inactive = #"{"error":{"code":"integration_credits_exhausted","message":"The user has no active plan, so connected tools cannot be read."}}"#
        XCTAssertEqual(ChatToolGate.outcome(of: inactive), .outOfCredits)
    }
}
