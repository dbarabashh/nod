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

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
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
                    .map { CalendarAttendee(display: $0.name, isSelf: $0.email.lowercased() == mine) },
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
