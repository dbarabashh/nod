import XCTest
@testable import Nod

/// A failure's recovery is the button the user gets offered, so the mapping is
/// the part worth pinning: a Retry under "your plan doesn't cover this" is a
/// button guaranteed not to work, and one missing under a rate limit sends the
/// person back to retype a question that would have succeeded.
final class ChatFailureTests: XCTestCase {
    func testAPlanProblemOffersUpgradeRatherThanRetry() {
        let failure = ChatFailure(LLMProxyClient.ClientError.entitlementRequired)

        XCTAssertEqual(failure.recovery, .upgrade)
    }

    func testMeetingLimitOffersUpgrade() {
        XCTAssertEqual(ChatFailure(LLMProxyClient.ClientError.meetingLimitReached).recovery, .upgrade)
    }

    /// Nothing in a chat surface signs somebody back in or updates the app, so
    /// these carry no button at all rather than one that does nothing.
    func testFailuresWithNoInChatFixOfferNoButton() {
        for error in [
            LLMProxyClient.ClientError.unauthenticated,
            .updateRequired,
            .deviceConflict
        ] {
            let failure = ChatFailure(error)
            XCTAssertEqual(failure.recovery, ChatFailure.Recovery.none, "\(error)")
            XCTAssertNil(failure.recovery.label, "\(error)")
        }
    }

    func testRateLimitAndServerErrorsAreRetryable() {
        XCTAssertEqual(ChatFailure(LLMProxyClient.ClientError.requestFailed(status: 429, body: "")).recovery, .retry)
        XCTAssertEqual(ChatFailure(LLMProxyClient.ClientError.requestFailed(status: 503, body: "")).recovery, .retry)
    }

    /// The status and body stay reachable behind the disclosure. Dropping them
    /// makes every report of a broken chat unactionable.
    func testTheWireDetailSurvivesClassification() {
        let failure = ChatFailure(LLMProxyClient.ClientError.requestFailed(status: 502, body: "upstream timeout"))

        let detail = failure.detail ?? ""
        XCTAssertTrue(detail.contains("502"), detail)
        XCTAssertTrue(detail.contains("upstream timeout"), detail)
    }

    /// A dropped link is named as one so the row doesn't blame Nod, and so the
    /// turn can be picked up by itself when the path comes back.
    func testALostConnectionIsMarkedOffline() {
        let dropped = URLError(.notConnectedToInternet)

        XCTAssertTrue(ChatFailure(LLMProxyClient.ClientError.networkFailed(dropped)).isOffline)
        XCTAssertTrue(ChatFailure(dropped).isOffline)
    }

    /// A 500 is the server's problem, not the link's — resuming it the moment
    /// Wi-Fi flaps would retry something the network never broke.
    func testAServerErrorIsNotMarkedOffline() {
        XCTAssertFalse(ChatFailure(LLMProxyClient.ClientError.requestFailed(status: 500, body: "")).isOffline)
    }

    /// The steps a turn completed outlive the answer it never produced — the
    /// difference between "nothing happened" and "the ticket exists".
    func testCompletedStepsRideAlongWithTheFailure() {
        let step = ChatTurnStep(provider: .linear, action: "create_issue", detail: "Fix login", outcome: .ran)

        let failure = ChatFailure(LLMProxyClient.ClientError.emptyResponse, steps: [step])

        XCTAssertEqual(failure.steps.map(\.detail), ["Fix login"])
    }

    func testAnUnrecognisedErrorIsStillRetryableAndKeepsItsText() {
        struct Odd: LocalizedError {
            var errorDescription: String? {
                "something specific went wrong"
            }
        }

        let failure = ChatFailure(Odd())

        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertEqual(failure.detail, "something specific went wrong")
    }
}
