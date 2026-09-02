import SwiftUI

/// The pure half of Today: what to say and which rows count, separated from
/// the view so the same logic is testable without a window.
enum TodayBrief {
    /// Time-of-day greeting, first name when the profile has one.
    static func greeting(for displayName: String?, at date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let salute = switch hour {
        case 5 ..< 12: "Good morning"
        case 12 ..< 18: "Good afternoon"
        default: "Good evening"
        }
        guard let first = Profile.firstName(in: displayName) else { return salute }
        return "\(salute), \(first)"
    }

    /// "Starts in 24 min" / "Started 5 min ago" / "Today at 19:00" — and
    /// "Tomorrow at 07:00" when the 12-hour window crosses midnight, because a
    /// morning meeting called "Today" at 8pm is a meeting somebody misses.
    static func startLine(for occurrence: CalendarOccurrence, now: Date) -> String {
        let minutes = Int(occurrence.startsAt.timeIntervalSince(now) / 60)
        if minutes < 0 { return "Started \(-minutes) min ago" }
        if minutes == 0 { return "Starting now" }
        if minutes <= 90 { return "Starts in \(minutes) min" }
        let day = Calendar.current.isDate(occurrence.startsAt, inSameDayAs: now) ? "Today" : "Tomorrow"
        return "\(day) at \(occurrence.startsAt.formatted(date: .omitted, time: .shortened))"
    }

    /// The card's one CTA, named for the meeting it starts — "Start capture"
    /// beside the sidebar's capture button was the same action twice.
    static func captureLabel(for occurrence: CalendarOccurrence) -> String {
        let title = occurrence.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return "Start capture" }
        let shown = title.count <= 28 ? title : String(title.prefix(27)).trimmingCharacters(in: .whitespaces) + "…"
        return "Start “\(shown)”"
    }

    /// What the last conversation left behind, in one line.
    static func knowledgeLine(for meeting: Meeting) -> String {
        let summary = SessionKnowledge.of(meeting).summary
        return summary.isEmpty ? "no structured recap" : summary
    }

    /// The most recent session with any of the same people, the invitation
    /// itself when both sides carry it. This is the "he remembered before I
    /// did" line — what the last conversation with these people left behind.
    ///
    /// Names match on their first word, whole: substring matching made "Ed"
    /// every Edward on the calendar, and an attendee whose display is a bare
    /// address matches on the address's own first token.
    static func lastSession(before occurrence: CalendarOccurrence, in meetings: [Meeting]) -> Meeting? {
        let live = meetings.live()
        if let externalID = occurrence.externalID,
           let matched = live.first(where: { $0.icalUID == externalID }) {
            return matched
        }
        let others = occurrence.others.compactMap { nameToken($0.display) }
        guard !others.isEmpty else { return nil }
        return live.first { meeting in
            let voices = (meeting.speakerNames?.values).map(Array.init) ?? []
            return voices.compactMap(nameToken).contains { others.contains($0) }
        }
    }

    /// The first word of a display name, lowercased — "Sasha K" → "sasha",
    /// "john.smith@acme.com" → "john". Nil when too short to identify anyone.
    static func nameToken(_ display: String) -> String? {
        let first = display
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init)
        guard let first, first.count >= 3 else { return nil }
        return first
    }

    /// A beat result counts as new until the person has opened Beats from its
    /// row. Kept per beat in defaults rather than a column: which mornings this
    /// Mac has shown is this Mac's business.
    private static func seenKey(_ beat: Beat) -> String {
        "today.beatSeen.\(beat.id.uuidString)"
    }

    static func isUnseen(_ run: BeatRun, of beat: Beat) -> Bool {
        run.scheduledFor.timeIntervalSince1970 > UserDefaults.standard.double(forKey: seenKey(beat))
    }

    static func markSeen(_ run: BeatRun, of beat: Beat) {
        UserDefaults.standard.set(run.scheduledFor.timeIntervalSince1970, forKey: seenKey(beat))
    }
}
