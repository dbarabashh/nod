import XCTest
@testable import Nod

/// "Not now" on the room card. The bug this pins had two faces and one cause:
/// the dismissal kept no memory, so the twenty-second discovery tick put the
/// card straight back, and the pre-start check read the cleared offer as
/// "never asked" — rediscovered the room and refused to record.
@MainActor
final class LiveRoomDismissalTests: XCTestCase {
    private let room = LiveRoom(hostName: "Dima", startedAt: Date())
    private let standup = RoomIdentity(icalUID: "standup@acme", conferenceURL: nil)
    private let review = RoomIdentity(icalUID: "review@acme", conferenceURL: nil)

    private func service(offering identity: RoomIdentity) -> RoomListenerService {
        .preview(available: room, availableIdentity: identity)
    }

    func testDecliningIsRememberedForThatMeeting() {
        let rooms = service(offering: standup)
        rooms.declineRoom()

        XCTAssertNil(rooms.available)
        XCTAssertTrue(rooms.isDeclined(standup))
    }

    /// The other half of the report: a start that follows a dismissal must not
    /// be answered with the same card again.
    func testADeclinedRoomIsNotOfferedBeforeAStart() {
        let rooms = service(offering: standup)
        rooms.declineRoom()

        XCTAssertTrue(rooms.isDeclined(standup))
    }

    func testTheNextMeetingIsStillOffered() {
        let rooms = service(offering: standup)
        rooms.declineRoom()

        XCTAssertFalse(rooms.isDeclined(review))
    }

    /// The calendar moving on is not the user answering. This path runs on the
    /// discovery tick whenever nothing names the moment, and declining there
    /// would silence a room nobody was ever shown.
    func testForgettingIsNotDeclining() {
        let rooms = service(offering: standup)
        rooms.forgetRoom()

        XCTAssertNil(rooms.available)
        XCTAssertFalse(rooms.isDeclined(standup))
    }

    /// Nothing to name means nothing to remember — a blank key would decline
    /// every room at once.
    func testAnAnonymousRoomDeclinesNothing() {
        let rooms = RoomListenerService.preview(available: room, availableIdentity: nil)
        rooms.declineRoom()

        XCTAssertFalse(rooms.isDeclined(RoomIdentity(icalUID: nil, conferenceURL: nil)))
    }
}
