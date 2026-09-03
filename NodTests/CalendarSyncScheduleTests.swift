import XCTest
@testable import Nod

/// Every read of a connected calendar is a metered request, and the schedule
/// is the client's half of the floors `calendar-sync` enforces. An ask the
/// server would refuse must not be sent; an ask that is owed must not be
/// missed.
final class CalendarSyncScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func schedule(readAgo seconds: TimeInterval) -> CalendarSyncSchedule {
        var schedule = CalendarSyncSchedule()
        schedule.answered(.open, read: true, readAt: now.addingTimeInterval(-seconds), now: now.addingTimeInterval(-seconds))
        return schedule
    }

    func testANeverReadCalendarMayBeAskedForAnyReason() {
        let fresh = CalendarSyncSchedule()
        for reason in [CalendarSyncReason.open, .idle, .approaching, .call] {
            XCTAssertTrue(fresh.mayAsk(reason, now: now), "\(reason)")
        }
    }

    func testEachReasonWaitsItsOwnFloor() {
        XCTAssertFalse(schedule(readAgo: 14 * 60).mayAsk(.open, now: now))
        XCTAssertTrue(schedule(readAgo: 15 * 60).mayAsk(.open, now: now))
        XCTAssertFalse(schedule(readAgo: 59 * 60).mayAsk(.idle, now: now))
        XCTAssertTrue(schedule(readAgo: 60 * 60).mayAsk(.idle, now: now))
        XCTAssertFalse(schedule(readAgo: 4 * 60).mayAsk(.approaching, now: now))
        XCTAssertTrue(schedule(readAgo: 5 * 60).mayAsk(.approaching, now: now))
        XCTAssertFalse(schedule(readAgo: 119).mayAsk(.call, now: now))
        XCTAssertTrue(schedule(readAgo: 120).mayAsk(.call, now: now))
    }

    /// The floors here are the ones `calendarRefresh.ts` enforces. A mismatch
    /// either sends asks the server refuses or leaves freshness on the table.
    func testFloorsMirrorTheServer() {
        XCTAssertEqual(CalendarSyncReason.open.floor, 15 * 60)
        XCTAssertEqual(CalendarSyncReason.idle.floor, 60 * 60)
        XCTAssertEqual(CalendarSyncReason.approaching.floor, 5 * 60)
        XCTAssertEqual(CalendarSyncReason.call.floor, 2 * 60)
    }

    /// The case the read exists for: an entry within the half hour, and the
    /// last read was long enough ago.
    func testAMeetingWithinHalfAnHourIsApproaching() {
        let schedule = schedule(readAgo: 6 * 60)
        XCTAssertEqual(schedule.due(nextStart: now.addingTimeInterval(20 * 60), now: now), .approaching)
    }

    func testAMeetingJustStartedStillCountsAsApproaching() {
        let schedule = schedule(readAgo: 6 * 60)
        XCTAssertEqual(schedule.due(nextStart: now.addingTimeInterval(-3 * 60), now: now), .approaching)
    }

    /// Ten minutes into the meeting the person either joined — and the call
    /// detector has it — or is not coming; reading again buys nothing.
    func testAMeetingWellUnderWayIsNotApproaching() {
        let schedule = schedule(readAgo: 6 * 60)
        XCTAssertNil(schedule.due(nextStart: now.addingTimeInterval(-10 * 60), now: now))
    }

    func testAMeetingAnHourOutIsNotApproaching() {
        let schedule = schedule(readAgo: 6 * 60)
        XCTAssertNil(schedule.due(nextStart: now.addingTimeInterval(60 * 60), now: now))
    }

    /// Twelve reads an hour before a meeting would be the ten-minute sweep
    /// back under another name.
    func testApproachingStillWaitsItsFloor() {
        let schedule = schedule(readAgo: 3 * 60)
        XCTAssertNil(schedule.due(nextStart: now.addingTimeInterval(10 * 60), now: now))
    }

    func testAnHourOfQuietOwesAnIdleRead() {
        XCTAssertEqual(schedule(readAgo: 61 * 60).due(nextStart: nil, now: now), .idle)
        XCTAssertNil(schedule(readAgo: 30 * 60).due(nextStart: nil, now: now))
    }

    /// Most accounts never connect a calendar. A tick every twenty seconds,
    /// Today's every reload and every activation must not each send an ask to
    /// learn that again — nothing is asked until the connection changes.
    func testNotConnectedQuietsEveryAskUntilTheConnectionChanges() {
        var schedule = CalendarSyncSchedule()
        schedule.notConnected(at: now)
        XCTAssertNil(schedule.due(nextStart: now.addingTimeInterval(60), now: now))
        for reason in [CalendarSyncReason.open, .idle, .approaching, .call] {
            XCTAssertFalse(schedule.mayAsk(reason, now: now.addingTimeInterval(23 * 60 * 60)), "\(reason)")
        }
        schedule.connectionChanged()
        XCTAssertTrue(schedule.mayAsk(.open, now: now))
        XCTAssertEqual(schedule, CalendarSyncSchedule())
    }

    func testAFailureHoldsEveryAskBriefly() {
        var schedule = CalendarSyncSchedule()
        schedule.failed(at: now)
        XCTAssertFalse(schedule.mayAsk(.open, now: now.addingTimeInterval(4 * 60)))
        XCTAssertFalse(schedule.mayAsk(.call, now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(schedule.mayAsk(.approaching, now: now.addingTimeInterval(5 * 60)))
    }

    /// The server's stamp wins: a refused ask still tells the client when the
    /// last read was, so the next floor is measured from the truth.
    func testAnAnswerAdoptsTheServersStampAndClearsTheHold() {
        var schedule = CalendarSyncSchedule()
        schedule.failed(at: now)
        schedule.answered(.approaching, read: true, readAt: now.addingTimeInterval(-10 * 60), now: now)
        XCTAssertNil(schedule.holdUntil)
        XCTAssertEqual(schedule.lastRead, now.addingTimeInterval(-10 * 60))
        XCTAssertFalse(schedule.mayAsk(.open, now: now))
        XCTAssertTrue(schedule.mayAsk(.approaching, now: now))
    }

    /// A Mac whose clock runs ahead of the server's would otherwise re-send
    /// the refused ask on the next tick and be refused again, every twenty
    /// seconds, for the length of the floor.
    func testARefusalWaitsTheFloorFromTheRefusalNotFromThisClock() {
        var schedule = CalendarSyncSchedule()
        let serverStamp = now.addingTimeInterval(-20 * 60)
        schedule.answered(.open, read: false, readAt: serverStamp, now: now)
        XCTAssertFalse(schedule.mayAsk(.open, now: now.addingTimeInterval(14 * 60)))
        XCTAssertTrue(schedule.mayAsk(.open, now: now.addingTimeInterval(15 * 60)))
        XCTAssertTrue(schedule.mayAsk(.call, now: now), "a different reason has its own floor")
    }

    func testAReadClearsEveryEarlierRefusal() {
        var schedule = CalendarSyncSchedule()
        schedule.answered(.open, read: false, readAt: now.addingTimeInterval(-60), now: now)
        schedule.answered(.call, read: true, readAt: now, now: now)
        XCTAssertTrue(schedule.mayAsk(.open, now: now.addingTimeInterval(15 * 60)))
    }

    func testAnAnswerWithoutAStampKeepsTheLastOne() {
        var schedule = schedule(readAgo: 60)
        schedule.answered(.open, read: false, readAt: nil, now: now)
        XCTAssertEqual(schedule.lastRead, now.addingTimeInterval(-60))
    }

    /// The month's budget is the server's, on its clock, and nothing this Mac
    /// says changes it before the month turns — except a recording starting,
    /// which the server does not count either.
    func testACapHoldsTheTimedAsksUntilTheNextMonth() {
        var schedule = CalendarSyncSchedule()
        let midMonth = Date(timeIntervalSince1970: 1_757_000_000)
        schedule.capped(at: midMonth)
        let later = midMonth.addingTimeInterval(20 * 24 * 60 * 60)
        XCTAssertFalse(schedule.mayAsk(.approaching, now: later))
        XCTAssertFalse(schedule.mayAsk(.open, now: later))
        XCTAssertTrue(schedule.mayAsk(.call, now: later))
        XCTAssertEqual(schedule.cappedUntil, Date(timeIntervalSince1970: 1_759_276_800), "2025-10-01T00:00:00Z")
        XCTAssertTrue(schedule.mayAsk(.open, now: Date(timeIntervalSince1970: 1_759_276_800)))
    }

    /// At launch the sign-in read lands before the link list does; learning
    /// the calendar is connected must not forget the read the server just made.
    func testReconnectingLiftsTheHoldAndKeepsTheStamp() {
        var schedule = CalendarSyncSchedule()
        schedule.answered(.open, read: true, readAt: now, now: now)
        schedule.notConnected(at: now)
        schedule.reconnected()
        XCTAssertNil(schedule.holdUntil)
        XCTAssertEqual(schedule.lastRead, now)
        XCTAssertFalse(schedule.mayAsk(.open, now: now.addingTimeInterval(60)))
    }

    func testTheServersStampParsesWithOrWithoutAFraction() {
        XCTAssertEqual(RemoteCalendar.stamp("2026-09-02T10:00:00.123Z")?.timeIntervalSince1970 ?? 0, 1_788_343_200.123, accuracy: 0.001)
        XCTAssertEqual(RemoteCalendar.stamp("2026-09-02T10:00:00Z"), Date(timeIntervalSince1970: 1_788_343_200))
        XCTAssertNil(RemoteCalendar.stamp("not a stamp"))
    }
}
