import Combine
import Foundation
import Supabase

/// The calendar as our servers read it, for the Mac that cannot read it itself.
///
/// `CalendarService` answers from EventKit, which only knows the accounts added
/// to Calendar.app. A Google calendar connected through the Integrations pane is
/// invisible to it — the sync writes those events to `calendar_events` and, until
/// this existed, nothing in the app ever looked. So a person who connected their
/// calendar exactly as we asked still got no meeting reminders and no offer to
/// join a colleague's room.
///
/// Read-through, never a second opinion: `CalendarService` merges this behind
/// EventKit and drops anything already known by invitation id, so a calendar
/// present in both places is one meeting rather than two.
@MainActor
final class RemoteCalendar: ObservableObject {
    @Published private(set) var occurrences: [CalendarOccurrence] = []

    /// Who this Mac is signed in as, so the roster can tell the user apart from
    /// everyone else. EventKit answers this directly; a row from the server has
    /// only addresses, so the comparison has to happen here.
    var selfEmail: String?

    private let supabase: SupabaseClient?
    private var lastRefresh: Date?
    /// What the server last said about when it read, and so when it may be
    /// asked again.
    private(set) var schedule = CalendarSyncSchedule()
    private var askInFlight: Task<Bool, Never>?
    private var linkObserver: AnyCancellable?

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    /// Whether the connected calendar is a source worth asking. An account that
    /// connected nothing loads nothing, and the watcher must not keep working
    /// for a calendar that is not there.
    var hasOccurrences: Bool {
        !occurrences.isEmpty
    }

    /// Previews and tests: a connected calendar that already holds these, with
    /// no backend to load them from.
    static func preview(_ occurrences: [CalendarOccurrence]) -> RemoteCalendar {
        let calendar = RemoteCalendar(supabase: nil)
        calendar.adopt(occurrences)
        return calendar
    }

    /// Seam for the same: the real load path is a network read.
    func adopt(_ occurrences: [CalendarOccurrence]) {
        self.occurrences = occurrences
    }

    /// Learns when the calendar is connected or disconnected, which is the
    /// one event that makes a "not connected" answer stale. Coming back from
    /// the browser after connecting is the moment Today should fill, and the
    /// hold that quietened the ticks must not outlive the reason for it.
    func follow(_ integrations: IntegrationService) {
        linkObserver = integrations.$linked
            .map { $0.contains(.googleCalendar) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    // The hold goes, the server's last stamp stays: at launch
                    // the sign-in read lands before the link list does, and
                    // forgetting it here would send an ask the server refuses.
                    schedule.reconnected()
                    Task { await self.sync(.open) }
                } else {
                    schedule.connectionChanged()
                    occurrences = []
                }
            }
    }

    /// Re-reads when the snapshot has aged past `maxAge`.
    ///
    /// Activation alone is not enough. A Mac sitting with Nod in the background
    /// while a colleague schedules something two minutes out holds a snapshot
    /// from whenever it was last brought forward — and the entry that snapshot
    /// cannot contain is the entire offer.
    func refreshIfStale(maxAge: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        await refresh()
    }

    /// Asks the server to read the connected calendar again for `reason`, when
    /// that reason's floor allows, then brings the snapshot forward.
    ///
    /// The server is what reads Google — this Mac holds no token and never
    /// will. What it can do is say *why* now is worth a read: the app came
    /// forward, a meeting is about to start, a recording is beginning. Each
    /// reason has a floor, mirrored in `CalendarSyncReason.floor` and enforced
    /// in `calendar-sync`, and a read that lands nothing new still moves the
    /// floor — that is the cost model, not a cache.
    func sync(_ reason: CalendarSyncReason) async {
        let read = await ask(reason)
        if read {
            await refresh()
        } else {
            await refreshIfStale(maxAge: 60)
        }
    }

    /// A watcher tick's share: the periodic ask if one is owed.
    ///
    /// `approaching` when an entry starts within the next half hour — the one
    /// moved five minutes before it begins is the case the read exists for —
    /// and `idle` once an hour otherwise, so an invitation created while the
    /// app sat in the background is not first seen when it is already over.
    func syncIfDue(now: Date = Date()) async {
        let soon = occurrences(
            startingBetween: now.addingTimeInterval(-CalendarSyncSchedule.approachingGrace),
            and: now.addingTimeInterval(CalendarSyncSchedule.approachingWindow)
        )
        guard let reason = schedule.due(nextStart: soon.first?.startsAt, now: now) else { return }
        if await ask(reason) {
            await refresh()
        }
    }

    /// Whether the server read the calendar for this ask.
    ///
    /// One ask at a time. A second caller waits for the first rather than
    /// being dropped: a recording starting the second Today asked must still
    /// get its answer, and after the first lands the floor decides.
    private func ask(_ reason: CalendarSyncReason) async -> Bool {
        guard let supabase else { return false }
        while let inFlight = askInFlight {
            _ = await inFlight.value
            // Awaiting a finished task does not suspend, so the caller that
            // owns it never gets the actor back to clear it. The waiter does.
            if askInFlight == inFlight { askInFlight = nil }
        }
        let now = Date()
        guard schedule.mayAsk(reason, now: now) else { return false }
        let task = Task { await send(reason, through: supabase, at: now) }
        askInFlight = task
        let read = await task.value
        if askInFlight == task { askInFlight = nil }
        return read
    }

    private func send(_ reason: CalendarSyncReason, through supabase: SupabaseClient, at now: Date) async -> Bool {
        do {
            let answer: SyncAnswer = try await supabase.functions.invoke(
                "calendar-sync",
                options: FunctionInvokeOptions(body: SyncRequest(reason: reason.rawValue))
            )
            return absorb(answer, for: reason, at: now)
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch let FunctionsError.httpError(code, _) where code == 403 {
            // The organization said no. Nothing this Mac does changes that,
            // so it is held like a calendar nobody connected.
            schedule.notConnected(at: now)
            Log.ui.info("calendar: the organization does not permit the calendar")
            return false
        } catch {
            schedule.failed(at: now)
            Log.ui.error("calendar: ask (\(reason.rawValue)) failed: \(error.localizedDescription)")
            return false
        }
    }

    private func absorb(_ answer: SyncAnswer, for reason: CalendarSyncReason, at now: Date) -> Bool {
        guard answer.connected else {
            schedule.notConnected(at: now)
            return false
        }
        if answer.capped == true {
            schedule.capped(at: now)
            Log.ui.error("calendar: this month's reads are spent")
            return false
        }
        schedule.answered(reason, read: answer.read, readAt: answer.syncedAt.flatMap(Self.stamp(_:)), now: now)
        Log.ui.info("calendar: asked (\(reason.rawValue)) → \(answer.read ? "read" : "not yet")")
        return answer.read
    }

    /// The server normalises its stamps to `toISOString()` — fractional, Z —
    /// but a stamp without a fraction is still a stamp.
    nonisolated static func stamp(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    private nonisolated static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated static let whole = ISO8601DateFormatter()

    func refresh() async {
        guard let supabase else { return }
        do {
            let rows: [Row] = try await supabase
                .from("calendar_events")
                .select("title, starts_at, ends_at, ical_uid, conference_url, attendees")
                .order("starts_at", ascending: true)
                .execute()
                .value
            // Guarded: every observer of `occurrences` re-derives on a publish,
            // and the snapshot is re-read about once a minute for the life of
            // the app.
            let next = rows.map { $0.occurrence(selfEmail: selfEmail) }
            if next != occurrences { occurrences = next }
            lastRefresh = Date()
        } catch {
            Log.ui.error("RemoteCalendar.refresh failed: \(error.localizedDescription)")
        }
    }

    func occurrences(overlapping span: DateInterval) -> [CalendarOccurrence] {
        occurrences.filter { $0.startsAt <= span.end && $0.endsAt >= span.start }
    }

    func occurrences(startingBetween start: Date, and end: Date) -> [CalendarOccurrence] {
        occurrences.filter { $0.startsAt >= start && $0.startsAt <= end }
    }

    /// The invitation a finished meeting was matched to.
    ///
    /// Fetched rather than read out of `occurrences`: that list is the rolling
    /// window the sync keeps, and a meeting being repaired days later is outside
    /// it. This is the only persisted record of who was in the room — the
    /// conferencing roster is session-scoped by policy and gone — so it is what
    /// lets a meeting whose finalize failed still learn whose voice it heard.
    func occurrence(forICalUID uid: String) async -> CalendarOccurrence? {
        guard let supabase else { return nil }
        do {
            let rows: [Row] = try await supabase
                .from("calendar_events")
                .select("title, starts_at, ends_at, ical_uid, conference_url, attendees")
                .eq("ical_uid", value: uid)
                .limit(1)
                .execute()
                .value
            return rows.first.map { $0.occurrence(selfEmail: selfEmail) }
        } catch {
            Log.ui.error("invitation lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The evidence-linked "last time" sentence for an upcoming occurrence,
    /// when the server found a confident prior-meeting match — see
    /// `link_prior_meeting_for_calendar_source_object` and D0036 in the
    /// playbook. Nil is the common, correct answer today: the matcher is
    /// deliberately conservative, so most occurrences have no briefing yet.
    func briefing(forICalUID uid: String) async -> MeetingBriefing? {
        guard let supabase else { return nil }
        do {
            let rows: [MeetingBriefing] = try await supabase
                .rpc("get_upcoming_meeting_briefing", params: ["p_ical_uid": uid])
                .execute()
                .value
            return rows.first
        } catch {
            Log.ui.error("briefing lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sign-out. The schedule goes with the rows: whoever signs in next is
    /// owed a read, not the last account's floor.
    func clear() {
        occurrences = []
        schedule.connectionChanged()
        lastRefresh = nil
    }

    /// `meetingID` names the SAME meeting `summary` is about, resolved
    /// server-side through the briefing's own evidence chain — never through
    /// `TodayBrief.lastSession`'s independent (and looser) attendee-name
    /// heuristic, so the sentence and its "From <meeting>" attribution can
    /// never disagree about which meeting either one means.
    struct MeetingBriefing: Decodable, Equatable {
        let headline: String?
        let summary: String
        let confidence: Double
        let meetingID: UUID
        let meetingTitle: String?
        let meetingOccurredAt: Date?

        enum CodingKeys: String, CodingKey {
            case headline, summary, confidence
            case meetingID = "meeting_id"
            case meetingTitle = "meeting_title"
            case meetingOccurredAt = "meeting_occurred_at"
        }
    }

    private struct Row: Decodable {
        let title: String?
        let starts_at: Date
        let ends_at: Date
        let ical_uid: String?
        let conference_url: String?
        let attendees: [Attendee]?

        struct Attendee: Decodable {
            let email: String
            /// The name the invitation carried, when it carried one.
            let display: String?
            let response: String

            /// Google's own name first. `CalendarAttendee.display(from:)` is a
            /// last resort that reads a name out of an address, and it cannot
            /// know that `riwwom@gmail.com` is a person called something else.
            var name: String {
                display.map { $0.isEmpty ? email : $0 } ?? CalendarAttendee.display(from: email)
            }
        }

        func occurrence(selfEmail: String?) -> CalendarOccurrence {
            let url = conference_url.flatMap(URL.init(string:))
            let mine = selfEmail?.lowercased()
            return CalendarOccurrence(
                title: title ?? "",
                startsAt: starts_at,
                endsAt: ends_at,
                host: url.flatMap(Self.host),
                // Declined invitations are dropped here rather than at the sync,
                // which keeps the record honest about who was asked.
                attendees: (attendees ?? [])
                    .filter { $0.response != "declined" }
                    .map { CalendarAttendee(display: $0.name, isSelf: $0.email.lowercased() == mine, email: $0.email) },
                externalID: ical_uid,
                conferenceURL: url
            )
        }

        private static func host(_ url: URL) -> ConferencingHost? {
            guard let host = url.host?.lowercased() else { return nil }
            return ConferencingHost.allCases.first { $0.markers.contains(where: host.contains) }
        }
    }
}

private struct SyncRequest: Encodable {
    let reason: String
}

private struct SyncAnswer: Decodable {
    let connected: Bool
    let read: Bool
    let syncedAt: String?
    let capped: Bool?

    enum CodingKeys: String, CodingKey {
        case connected, read, capped
        case syncedAt = "synced_at"
    }
}
