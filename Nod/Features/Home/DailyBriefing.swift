import Foundation

/// The once-a-day read: what is ahead, what is owed, and what recent sessions
/// left open — one screen, built from data already on this Mac.
///
/// A namespace, not a stored value. The rows are rebuilt from live data on
/// every look because they go stale within the hour, and the prose is the only
/// thing worth holding on to — so there is nothing here to persist, and nothing
/// to leave behind in `UserDefaults` after an account is deleted.
enum DailyBriefing {
    struct Row: Equatable, Identifiable {
        let kind: Kind
        let title: String
        let subtitle: String?
        /// Trailing label — a time, a resolved deadline, how long ago.
        let meta: String?
        /// The session behind this row, so it can be opened. Nil for calendar
        /// entries, which Nod has no recording of.
        let meetingID: UUID?
        /// When a calendar entry begins, so the lead can count down to it
        /// rather than repeat a clock time the menu bar already shows.
        let startsAt: Date?

        /// What this row *is*, with nothing in it that moves on its own.
        ///
        /// Separate from `id` because `id` carries `meta`, and `meta` is a
        /// relative phrase — "2 hr ago" becomes "3 hr ago" while nothing about
        /// the row changed. Keying the prose on `id` therefore rewrote the
        /// briefing every hour for a day that had not moved.
        var factKey: String {
            [kind.rawValue, meetingID?.uuidString ?? "", title].joined(separator: "|")
        }

        var id: String {
            [kind.rawValue, title, subtitle ?? "", meta ?? ""].joined(separator: "|")
        }
    }

    enum Kind: String {
        /// A calendar entry that has not ended yet.
        case ahead
        /// An open action item.
        case owed
        /// A question or deferred decision a recent session left open.
        case loose
    }
}

extension DailyBriefing {
    /// Everything the day has to say, grouped. Kept apart from `DailyBriefing`
    /// because this half is free: it is assembled without a network call, and
    /// an empty one is the signal not to make one.
    struct Facts: Equatable {
        let ahead: [Row]
        let owed: [Row]
        let loose: [Row]

        var rows: [Row] {
            ahead + owed + loose
        }

        var isEmpty: Bool {
            rows.isEmpty
        }

        /// The one thing this screen exists to say out loud. The next meeting
        /// wins when the day still holds one — it is the only item here with a
        /// time you cannot move — and the most urgent commitment otherwise.
        var lead: Row? {
            ahead.first ?? owed.first
        }

        /// Everything the lead already said, said once. Dropping by position
        /// rather than by matching `id`: two tasks can read identically, and
        /// filtering removed both of them.
        var rest: Facts {
            ahead.isEmpty
                ? Facts(ahead: [], owed: Array(owed.dropFirst()), loose: loose)
                : Facts(ahead: Array(ahead.dropFirst()), owed: owed, loose: loose)
        }
    }

    /// The opening line, computed rather than written. Which half of the day it
    /// is is a comparison against the clock, and that is the one thing this app
    /// never hands to a model — a briefing opened at six in the evening that
    /// says "good morning" is a briefing nobody believes the rest of.
    static func greeting(name: String?, now: Date) -> String {
        let hour = Foundation.Calendar.current.component(.hour, from: now)
        let part = switch hour {
        case ..<5: "Still up"
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
        guard let name, !name.isEmpty else { return part }
        return "\(part), \(name)"
    }

    /// How long until something starts, for the one row that leads. "In 40
    /// minutes" is what a person needs from a calendar entry at breakfast;
    /// "09:30" is what they need from it at 09:25, and the menu bar has that.
    static func countdown(to date: Date, from now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Now" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours >= 6 { return nil }
        return rest == 0 ? "In \(hours)h" : "In \(hours)h \(rest)m"
    }

    /// Beyond these the screen stops being a briefing and becomes a list. The
    /// numbers differ per group on purpose: a day has as many meetings as it
    /// has, but the fourth loose end from a fortnight ago is noise.
    private enum Limit {
        static let ahead = 6
        static let owed = 5
        static let loose = 3
    }

    static func facts(
        meetings: [Meeting],
        actionItems: [ActionItem],
        events: [CalendarOccurrence],
        now: Date
    ) -> Facts {
        Facts(
            ahead: aheadRows(events: events, now: now),
            owed: owedRows(meetings: meetings, actionItems: actionItems, now: now),
            loose: looseRows(meetings: meetings, now: now)
        )
    }

    /// Today's remaining calendar. An event that already ended is not "ahead",
    /// and one running right now is — the comparison is made here rather than
    /// left to the model, the same rule `KnowledgeChatStore.calendarStatus` follows.
    private static func aheadRows(events: [CalendarOccurrence], now: Date) -> [Row] {
        events
            .filter { Foundation.Calendar.current.isDate($0.startsAt, inSameDayAs: now) && $0.endsAt > now }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(Limit.ahead)
            .map { event in
                Row(
                    kind: .ahead,
                    title: event.title,
                    subtitle: CallContext.withLine(event.others.map(\.display)),
                    meta: timeFormatter.string(from: event.startsAt),
                    meetingID: nil,
                    startsAt: event.startsAt
                )
            }
    }

    private static func owedRows(meetings: [Meeting], actionItems: [ActionItem], now: Date) -> [Row] {
        TodayDigest.openActions(items: actionItems, meetings: meetings, now: now, limit: Limit.owed)
            .map { open in
                Row(
                    kind: .owed,
                    title: open.item.text,
                    subtitle: open.meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    meta: open.deadline?.text,
                    meetingID: open.meeting.id,
                    startsAt: nil
                )
            }
    }

    private static func looseRows(meetings: [Meeting], now: Date) -> [Row] {
        TodayDigest.openPoints(meetings: meetings, now: now, limit: Limit.loose)
            .map { point in
                Row(
                    kind: .loose,
                    title: point.text,
                    subtitle: point.meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    meta: Meeting.ago(point.meeting.startedAt),
                    meetingID: point.meeting.id,
                    startsAt: nil
                )
            }
    }

    /// What the last day was actually spent on, as one line per app: the
    /// window that held the screen longest, and how long the app had it.
    ///
    /// Titles only — never the captured text, and never fetched either: the
    /// plan is what the index alone yields, so the user's documents do not
    /// cross the wire to be discarded on arrival. What the briefing needs from
    /// ambient context is which piece of work a commitment belongs to, and a
    /// window title carries that.
    @MainActor
    static func screenLines(from plan: ScreenActivityPlan) -> [String] {
        plan.apps
            .prefix(screenAppLimit)
            .compactMap { app -> String? in
                let named = app.windows
                    .map(\.title)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard let named else { return nil }
                return "\(AppDirectory.identity(forBundleID: app.bundleID).name): \(named) (\(dwell(app.captures)))"
            }
    }

    /// Past this the prompt is being told about glances rather than about work.
    private static let screenAppLimit = 5

    /// A capture every `ScreenContextService.interval` seconds, so the count is
    /// time on screen. Rounded to the coarsest unit still true — "about 2h" is
    /// the honest reading of a poll that misses whatever happened between ticks.
    private static func dwell(_ captures: Int) -> String {
        let minutes = max(1, Int(Double(captures) * ScreenContextService.interval / 60))
        guard minutes >= 60 else { return "about \(minutes)m" }
        return "about \(minutes / 60)h\(minutes % 60 == 0 ? "" : "\(minutes % 60)m")"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
