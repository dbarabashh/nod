import XCTest
@testable import Nod

/// 1.4 moved the calendar to second and dropped the tutorial. Every earlier
/// build persisted a step by its *position*, so the arithmetic that carried
/// 1.0–1.3 forward can no longer do the job — a stored `4` used to mean the
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

    func testTheCalendarComesSecond() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .calendar, .permissions, .profile, .emailPreferences])
        XCTAssertEqual(OnboardingStep.calendar.position, 2)
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
        XCTAssertEqual(fields["currentStep"] as? Int, 4)
        XCTAssertEqual(try JSONDecoder().decode(OnboardingStatus.self, from: encoded).currentStep, .profile)
    }

    /// A name outranks the position beside it — that is what makes the next
    /// reorder a reorder rather than another migration.
    func testTheNameWinsOverAStalePosition() throws {
        let json = #"{"version":"1.5","stepName":"calendar","currentStep":4,"completed":false}"#
        let status = try JSONDecoder().decode(OnboardingStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.currentStep, .calendar)
    }

    /// The step that no longer exists. Whoever stood on it had already granted
    /// permissions and filled the profile; the calendar is what 1.3 had not yet
    /// asked them for, so that is where they resume.
    func testSomebodyStandingOnTheTutorialResumesAtTheCalendar() throws {
        XCTAssertEqual(try decode(step: 4, version: "1.3"), .calendar)
    }

    func testAStepFrom1_3KeepsItsIdentityRatherThanItsPosition() throws {
        XCTAssertEqual(try decode(step: 1, version: "1.3"), .welcome)
        XCTAssertEqual(try decode(step: 2, version: "1.3"), .profile)
        XCTAssertEqual(try decode(step: 3, version: "1.3"), .permissions)
        XCTAssertEqual(try decode(step: 5, version: "1.3"), .calendar)
        XCTAssertEqual(try decode(step: 6, version: "1.3"), .emailPreferences)
    }

    /// The oldest install we still migrate: 1.0 had no profile step and no
    /// calendar step, so both shifts have to run before the identity lookup.
    func testTheOldestNumberingStillResolves() throws {
        XCTAssertEqual(try decode(step: 1, version: "1.0"), .welcome)
        XCTAssertEqual(try decode(step: 2, version: "1.0"), .permissions)
        XCTAssertEqual(try decode(step: 4, version: "1.0"), .emailPreferences)
        XCTAssertEqual(try decode(step: 2, version: "1.1"), .profile)
        XCTAssertEqual(try decode(step: 5, version: "1.2"), .emailPreferences)
    }

    /// A value the current build wrote is already in the current numbering and
    /// must not be run through the rename table a second time.
    func testACurrentValueIsLeftAlone() throws {
        for step in OnboardingStep.allCases {
            XCTAssertEqual(try decode(step: step.position, version: "1.4"), step)
        }
    }

    func testAnUnknownStepFallsBackToTheStart() throws {
        XCTAssertEqual(try decode(step: 99, version: "1.3"), .welcome)
    }

    /// The flow steps over what this Mac has already answered, and keeps going
    /// in the same direction — stopping on the first satisfied step would leave
    /// it on a screen it had just decided not to show.
    func testAdvancingStepsOverWhatIsAlreadyAnswered() {
        XCTAssertEqual(
            OnboardingStep.welcome.advanced(by: 1, skipping: [.calendar, .permissions]),
            .profile
        )
    }

    /// Only the machine-level steps are ever passed in as satisfied. A person's
    /// own answers — their name, their email choice — are asked of every
    /// account, so the flow always lands on them.
    func testAPersonsOwnStepsAreNeverSkipped() {
        XCTAssertEqual(
            OnboardingStep.profile.advanced(by: 1, skipping: [.calendar, .permissions]),
            .emailPreferences
        )
    }

    /// Back out the same way, over the same steps.
    func testGoingBackStepsOverThemToo() {
        XCTAssertEqual(
            OnboardingStep.profile.advanced(by: -1, skipping: [.calendar, .permissions]),
            .welcome
        )
    }

    /// Nil at the ends rather than a wrap or a clamp: the caller stays put.
    func testThereIsNothingBeyondTheEnds() {
        XCTAssertNil(OnboardingStep.welcome.advanced(by: -1, skipping: []))
        XCTAssertNil(OnboardingStep.emailPreferences.advanced(by: 1, skipping: []))
    }
}
