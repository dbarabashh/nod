import XCTest
@testable import Nod

/// 1.6 moved everything after the profile into the notch. Every earlier
/// build persisted a step by its *position*, so the arithmetic that carried
/// 1.0–1.5 forward can no longer do the job — a stored `4` used to mean the
/// tutorial and now means the profile.
///
/// These start from each shipped numbering rather than from the current one:
/// a decode of the final schema proves nothing about an install that has been
/// through three of them.
final class OnboardingStepOrderTests: XCTestCase {
    private func decode(step: Int, version: String) throws -> OnboardingStep {
        let json = #"{"version":"\#(version)","currentStep":\#(step),"completed":false}"#
        let status = try JSONDecoder().decode(OnboardingStatus.self, from: Data(json.utf8))
        return status.currentStep
    }

    func testTheWindowAsksTwoThingsAndHandsOff() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .profile, .notch])
        XCTAssertEqual(OnboardingStep.notch.position, 3)
    }

    /// The expand phase: the name is what a current build reads back, and the
    /// legacy position is still written beside it so a downgrade to a build
    /// that only knows positions resumes on the same step.
    func testTheStepIsPersistedByNameAndByPosition() throws {
        var status = OnboardingStatus()
        status.currentStep = .profile
        let encoded = try JSONEncoder().encode(status)
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(fields["stepName"] as? String, "profile")
        XCTAssertEqual(fields["currentStep"] as? Int, 2)
        XCTAssertEqual(try JSONDecoder().decode(OnboardingStatus.self, from: encoded).currentStep, .profile)
    }

    /// A name outranks the position beside it — that is what makes the next
    /// reorder a reorder rather than another migration.
    func testTheNameWinsOverAStalePosition() throws {
        let json = #"{"version":"1.6","stepName":"profile","currentStep":1,"completed":false}"#
        let status = try JSONDecoder().decode(OnboardingStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.currentStep, .profile)
    }

    /// The three steps the window no longer shows. Whoever was standing on one
    /// resumes in the notch, which now asks the same things — and skips the
    /// ones this Mac has already answered.
    func testSomebodyStandingOnARetiredStepResumesInTheNotch() throws {
        for name in ["calendar", "permissions", "emailPreferences"] {
            let json = #"{"version":"1.5","stepName":"\#(name)","currentStep":2,"completed":false}"#
            let status = try JSONDecoder().decode(OnboardingStatus.self, from: Data(json.utf8))
            XCTAssertEqual(status.currentStep, .notch, name)
        }
        XCTAssertEqual(try decode(step: 2, version: "1.5"), .notch)
        XCTAssertEqual(try decode(step: 3, version: "1.4"), .notch)
        XCTAssertEqual(try decode(step: 5, version: "1.4"), .notch)
    }

    /// The step that no longer exists. Whoever stood on it had already granted
    /// permissions and filled the profile; the calendar is what 1.3 had not yet
    /// asked them for, and the notch is where the calendar is asked now.
    func testSomebodyStandingOnTheTutorialResumesInTheNotch() throws {
        XCTAssertEqual(try decode(step: 4, version: "1.3"), .notch)
    }

    func testAStepFrom1_3KeepsItsIdentityRatherThanItsPosition() throws {
        XCTAssertEqual(try decode(step: 1, version: "1.3"), .welcome)
        XCTAssertEqual(try decode(step: 2, version: "1.3"), .profile)
        XCTAssertEqual(try decode(step: 3, version: "1.3"), .notch)
    }

    /// The oldest install we still migrate: 1.0 had no profile step and no
    /// calendar step, so both shifts have to run before the identity lookup.
    func testTheOldestNumberingStillResolves() throws {
        XCTAssertEqual(try decode(step: 1, version: "1.0"), .welcome)
        XCTAssertEqual(try decode(step: 2, version: "1.0"), .notch)
        XCTAssertEqual(try decode(step: 2, version: "1.1"), .profile)
    }

    /// A value the current build wrote is already in the current numbering and
    /// must not be run through the rename table a second time.
    func testACurrentValueIsLeftAlone() throws {
        for step in OnboardingStep.allCases {
            XCTAssertEqual(try decode(step: step.position, version: "1.6"), step)
        }
    }

    func testAnUnknownStepFallsBackToTheStart() throws {
        XCTAssertEqual(try decode(step: 99, version: "1.3"), .welcome)
    }

    /// The flow steps over what is already answered, and keeps going in the
    /// same direction — stopping on the first satisfied step would leave it on
    /// a screen it had just decided not to show.
    func testAdvancingStepsOverWhatIsAlreadyAnswered() {
        XCTAssertEqual(OnboardingStep.welcome.advanced(by: 1, skipping: [.profile]), .notch)
    }

    /// Nil at the ends rather than a wrap or a clamp: the caller stays put.
    func testThereIsNothingBeyondTheEnds() {
        XCTAssertNil(OnboardingStep.welcome.advanced(by: -1, skipping: []))
        XCTAssertNil(OnboardingStep.notch.advanced(by: 1, skipping: []))
    }

    /// The setup cards skip what this Mac has already granted, so the flow
    /// itself only ever has to know its own order.
    func testTheNotchAsksInOrderAndCountsOnlyTheAsks() {
        XCTAssertEqual(NotchSetupStage.intro.next, .microphone)
        XCTAssertEqual(NotchSetupStage.calendar.next, .ready)
        XCTAssertNil(NotchSetupStage.firstAsk.next)
        XCTAssertEqual(NotchSetupStage.asks.map(\.askIndex), [0, 1, 2, 3])
        XCTAssertNil(NotchSetupStage.ready.askIndex)
    }
}
