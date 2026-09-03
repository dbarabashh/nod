import Foundation

/// Why the app is asking the server to read the connected calendar again.
///
/// Every read is a metered request through the integration broker, so the
/// server keeps a floor per reason (`calendarRefresh.ts`) and refuses anything
/// sooner. The floors are mirrored here so an ask the server would refuse is
/// never sent — the server's answer is still what the schedule is set from.
enum CalendarSyncReason: String {
    /// The app opened, came forward, or Today was shown.
    case open
    /// Nothing better has come up for an hour while the app runs.
    case idle
    /// A meeting on the calendar starts within half an hour.
    case approaching
    /// A recording is starting and the invitation is about to be matched.
    case call

    var floor: TimeInterval {
        switch self {
        case .open: 15 * 60
        case .idle: 60 * 60
        case .approaching: 5 * 60
        case .call: 2 * 60
        }
    }
}

/// When the next ask may go out, from what the server last said.
///
/// A value type with the clock passed in, so the arithmetic can be tested
/// without waiting an hour. `RemoteCalendar` owns the one that matters.
struct CalendarSyncSchedule: Equatable {
    /// When the server last read the calendar, by its own clock.
    private(set) var lastRead: Date?
    /// Nothing is asked before this: after a failure, a "not connected"
    /// answer, or a spent monthly budget.
    private(set) var holdUntil: Date?
    /// A refusal is the server's clock speaking. Each reason then waits its
    /// own floor from the refusal rather than re-arguing from this Mac's
    /// clock, which may be a floor ahead of the server's.
    private(set) var refusedUntil: [CalendarSyncReason: Date] = [:]
    /// The month's budget is spent; everything but a starting recording waits.
    private(set) var cappedUntil: Date?

    /// How far ahead a meeting counts as approaching.
    static let approachingWindow: TimeInterval = 30 * 60
    /// How long a meeting already under way still counts.
    static let approachingGrace: TimeInterval = 5 * 60
    static let failureHold: TimeInterval = 5 * 60
    /// A calendar nobody connected stays that way until the Integrations pane
    /// says otherwise, which `connectionChanged` reports; the day is a backstop.
    static let notConnectedHold: TimeInterval = 24 * 60 * 60

    func mayAsk(_ reason: CalendarSyncReason, now: Date) -> Bool {
        if let holdUntil, now < holdUntil { return false }
        if reason != .call, let cappedUntil, now < cappedUntil { return false }
        if let until = refusedUntil[reason], now < until { return false }
        guard let lastRead else { return true }
        return now.timeIntervalSince(lastRead) >= reason.floor
    }

    /// The ask a periodic tick owes, if any: `approaching` while a meeting
    /// starts within the window, `idle` once an hour otherwise.
    func due(nextStart: Date?, now: Date) -> CalendarSyncReason? {
        if let nextStart,
           nextStart.timeIntervalSince(now) <= Self.approachingWindow,
           nextStart.timeIntervalSince(now) >= -Self.approachingGrace,
           mayAsk(.approaching, now: now) {
            return .approaching
        }
        return mayAsk(.idle, now: now) ? .idle : nil
    }

    /// The server answered an ask. `readAt` is when it last read, fresh or
    /// not; `read` says whether this ask was the one that read.
    mutating func answered(_ reason: CalendarSyncReason, read: Bool, readAt: Date?, now: Date) {
        if let readAt { lastRead = readAt }
        holdUntil = nil
        if read {
            refusedUntil = [:]
        } else {
            refusedUntil[reason] = now.addingTimeInterval(reason.floor)
        }
    }

    /// The month's budget of reads is spent; nothing periodic is asked until
    /// the next. A recording starting is exempt on both sides — the server
    /// does not count it against the budget — because the read that names
    /// the meeting is the one worth keeping.
    mutating func capped(at now: Date) {
        cappedUntil = Self.startOfNextMonth(after: now)
    }

    /// The calendar has been connected again, or was found connected after a
    /// "not connected" answer. The hold goes; what the server said about its
    /// last read still stands.
    mutating func reconnected() {
        holdUntil = nil
    }

    mutating func notConnected(at now: Date) {
        holdUntil = now.addingTimeInterval(Self.notConnectedHold)
    }

    mutating func failed(at now: Date) {
        holdUntil = now.addingTimeInterval(Self.failureHold)
    }

    /// The calendar was connected or disconnected, or somebody else signed
    /// in: nothing the schedule held is about this calendar any more.
    mutating func connectionChanged() {
        self = CalendarSyncSchedule()
    }

    /// The budget resets on the server's month, which is UTC.
    static func startOfNextMonth(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let month = calendar.dateComponents([.year, .month], from: now)
        let next = DateComponents(year: month.year, month: (month.month ?? 1) + 1, day: 1)
        return calendar.date(from: next) ?? now.addingTimeInterval(24 * 60 * 60)
    }
}
