import XCTest
@testable import Nod

/// Onboarding used to offer one calendar — Google, through a browser round trip
/// — while the cheaper source sat behind a switch in Settings that the flow
/// never showed. `privacy.md` § 3.11 always described two, with an off-switch
/// each; these pin the step now offering both, and each row reading its own.
@MainActor
final class CalendarOptionTests: XCTestCase {
    func testTheDeviceRowOffersItselfUntilMacOSHasGrantedIt() throws {
        let service = try CalendarServiceFixture.service(switchedOn: false)
        XCTAssertEqual(CalendarSourceState.device(service), .offer)
    }

    /// Switching it on is not the grant. macOS answers separately, and until it
    /// does the row has to stay pressable — `ensureAccess` refuses to prompt
    /// with no key window, so a spinner here could never end.
    func testTheDeviceRowStaysPressableWhileTheGrantIsUndecided() throws {
        let service = try CalendarServiceFixture.service(switchedOn: true)
        XCTAssertEqual(service.status, .notDetermined)
        XCTAssertEqual(CalendarSourceState.device(service), .offer)
    }

    func testTheGoogleRowTracksTheConnection() {
        XCTAssertEqual(CalendarSourceState.google(.preview()), .offer)
        XCTAssertEqual(CalendarSourceState.google(.preview(linked: [.googleCalendar])), .connected)
    }

    /// The footer label asks what the user just did, not whether a sync has
    /// landed: `hasAnySource` is still false the second after Google connects,
    /// and "Not now" under a row reading "Connected" is a step that looks broken.
    func testConnectingGoogleAnswersTheStepBeforeAnyEventHasSynced() throws {
        let service = try CalendarServiceFixture.service(switchedOn: false)
        XCTAssertFalse(service.hasAnySource)
        XCTAssertTrue(
            CalendarSourceState.isAnswered(
                calendar: service,
                integrations: .preview(linked: [.googleCalendar])
            )
        )
    }

    func testNeitherSourceLeavesTheStepUnanswered() throws {
        XCTAssertFalse(
            try CalendarSourceState.isAnswered(calendar: CalendarServiceFixture.service(switchedOn: false), integrations: .preview())
        )
    }
}
