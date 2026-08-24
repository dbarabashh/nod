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

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    /// Whether the connected calendar is a source worth asking. An account that
    /// connected nothing loads nothing, and the watcher must not keep working
    /// for a calendar that is not there.
    var hasOccurrences: Bool {
        !occurrences.isEmpty
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

    func refresh() async {
        guard let supabase else { return }
        do {
            let rows: [Row] = try await supabase
                .from("calendar_events")
                .select("title, starts_at, ends_at, ical_uid, conference_url, attendees")
                .order("starts_at", ascending: true)
                .execute()
                .value
            occurrences = rows.map { $0.occurrence(selfEmail: selfEmail) }
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

    func clear() {
        occurrences = []
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
