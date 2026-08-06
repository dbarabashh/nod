import Foundation

/// One entry from the user's calendar, reduced to what a recording needs from
/// it: which meeting this is, and who is in it.
struct CalendarOccurrence: Equatable {
    let title: String
    let startsAt: Date
    let endsAt: Date
    /// The conferencing product this entry's own links point at, when they point
    /// anywhere. An entry with no link is still a meeting — plenty of people
    /// paste a room number and nothing else — it just cannot help tell two
    /// overlapping entries apart.
    let host: ConferencingHost?
    /// Everyone invited who has not declined, the user included.
    let attendees: [CalendarAttendee]

    /// The people other than the user — who the meeting is *with*, and how many
    /// voices other than the user's the recording should contain.
    var others: [CalendarAttendee] {
        attendees.filter { !$0.isSelf }
    }
}

/// The conferencing products a calendar link can name.
///
/// Separate from `ConferencingApp`, which is a bundle identifier: the same call
/// is Chrome on the Mac and `meet.google.com` in the invite, and neither name
/// knows about the other.
enum ConferencingHost: CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case whereby
    case discord

    /// Found anywhere in an event's link, location or notes.
    ///
    /// Deliberately *not* shared with the two window-title predicates
    /// (`MeetingRosterReader.isMeetingWindowTitle`, `MeetingDetection`), close as
    /// the lists look. Those answer different questions — "is this window safe
    /// to read" and "is a call happening right now" — and the second is narrower
    /// on purpose: Teams' domain is a marker for the first and must not be one
    /// for the second, or every Teams browser tab reads as a live call.
    var markers: [String] {
        switch self {
        case .zoom: ["zoom.us"]
        case .meet: ["meet.google.com"]
        case .teams: ["teams.microsoft.com", "teams.live.com"]
        case .webex: ["webex.com"]
        case .whereby: ["whereby.com"]
        case .discord: ["discord.gg", "discord.com"]
        }
    }

    static func named(in text: String) -> ConferencingHost? {
        let haystack = text.lowercased()
        return allCases.first { host in host.markers.contains { haystack.contains($0) } }
    }

    /// The Mac app a product runs in, when it has one — the inverse of
    /// `implied(by:)`, and what lets "Never for Zoom" reach a calendar entry
    /// that links to Zoom. Meet and Whereby live only in a browser, so there is
    /// no app to name and nothing to mute.
    static func nativeApp(_ host: ConferencingHost) -> ConferencingApp? {
        switch host {
        case .zoom: .zoom
        case .teams: .teams
        case .webex: .webex
        case .discord: .discord
        case .meet, .whereby: nil
        }
    }

    /// The product a running app implies — for a *native* app only.
    ///
    /// A browser implies nothing: Chrome hosts Meet, Teams, Webex and Whereby
    /// equally, so treating it as a constraint would rule out the right event
    /// rather than narrow to it.
    static func implied(by app: ConferencingApp) -> ConferencingHost? {
        switch app {
        case .zoom: .zoom
        case .teams, .teamsClassic: .teams
        case .webex: .webex
        case .discord: .discord
        case .slack, .chrome, .safari, .arc, .edge, .firefox, .brave: nil
        }
    }
}

extension CalendarOccurrence {
    /// Every entry the recording could belong to, best first.
    ///
    /// Matched against the *span* of the recording rather than against a moment,
    /// because the entry is not fixed when the recording starts. People create
    /// the invite two minutes before, or halfway through, or after everyone has
    /// hung up. Asked once when a call is noticed and once when the recording
    /// finishes; the second of those covers everything written in between,
    /// because by then the span is final and the question is about all of it
    /// rather than about the instant it was first asked.
    ///
    /// A list, not one answer: two entries genuinely competing for the same span
    /// is ordinary — a "hold" block over the real invite, back-to-back calls
    /// touching at the join. Every caller takes the first today; the rest are
    /// returned because deciding between them is the user's, and nothing here
    /// should have to change when something finally asks them.
    static func ranked(
        _ occurrences: [CalendarOccurrence],
        overlapping span: DateInterval,
        app: ConferencingApp?
    ) -> [CalendarOccurrence] {
        let expected = app.flatMap(ConferencingHost.implied)
        return occurrences
            .filter { $0.isPlausibleCall(during: span) }
            .sorted { $0.rank(against: expected, over: span) > $1.rank(against: expected, over: span) }
    }

    private func rank(against expected: ConferencingHost?, over span: DateInterval) -> Rank {
        Rank(
            matchesTheApp: host != nil && host == expected,
            hasACallLink: host != nil,
            overlap: interval.intersection(with: span)?.duration ?? 0,
            hasStarted: span.end >= startsAt,
            proximity: -abs(startsAt.timeIntervalSince(span.start))
        )
    }

    /// Why one candidate beats another, in priority order.
    ///
    /// Ranked rather than summed, because a sum hides its own priorities: adding
    /// "has a link" on top of a proximity score once let an entry that had not
    /// started beat one already under way. Compared in order that cannot happen.
    ///
    /// Overlap is the strongest evidence there is — an entry covering thirteen
    /// of a recording's fifteen minutes is the meeting, whatever else it carries
    /// — but it is silent at the moment a call is *noticed*, when nothing has
    /// been recorded yet and every candidate overlaps by zero. The two fields
    /// below carry that case, and only that case.
    private struct Rank: Comparable {
        let matchesTheApp: Bool
        let hasACallLink: Bool
        let overlap: TimeInterval
        /// The user is in this one; the next entry on the calendar has not
        /// happened yet.
        let hasStarted: Bool
        /// Nearest start, negated so closer sorts higher like everything else.
        /// Two identical holds around one real call is the ordinary shape of a
        /// busy calendar, and start time is what tells them apart.
        let proximity: TimeInterval

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.matchesTheApp != rhs.matchesTheApp { return rhs.matchesTheApp }
            if lhs.hasACallLink != rhs.hasACallLink { return rhs.hasACallLink }
            if lhs.overlap != rhs.overlap { return lhs.overlap < rhs.overlap }
            if lhs.hasStarted != rhs.hasStarted { return rhs.hasStarted }
            return lhs.proximity < rhs.proximity
        }
    }

    private var interval: DateInterval {
        DateInterval(start: startsAt, end: max(startsAt, endsAt))
    }

    private func isPlausibleCall(during span: DateInterval) -> Bool {
        // Touching counts: a recording begun a minute before the hour and an
        // entry starting on it share no seconds, and are plainly the same
        // meeting. `joinsEarly` is the whole slack allowed on either side.
        let reach = DateInterval(
            start: span.start.addingTimeInterval(-Self.joinsEarly),
            end: span.end.addingTimeInterval(Self.joinsEarly)
        )
        guard interval.intersects(reach) else { return false }
        // A block longer than an afternoon is working time someone has fenced
        // off — "focus", "offsite", "OOO" — not the call that just started.
        return endsAt.timeIntervalSince(startsAt) <= Self.longestCall
    }

    /// Slack on either side of the recording. It covers the people who dial in
    /// before the hour, and the recording someone stops a few minutes after the
    /// entry says the meeting ended.
    private static let joinsEarly: TimeInterval = 10 * 60
    private static let longestCall: TimeInterval = 4 * 60 * 60
}
