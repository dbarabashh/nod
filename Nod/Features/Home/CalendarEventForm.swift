import SwiftUI

/// The "schedule a follow-up" and "remind me" outcomes, carried out right here:
/// the form is the review — the person reads the title, the time and who is
/// invited, and the click on the one button below is the confirmation. Nothing
/// redirects to the chat for a field's worth of input.
struct CalendarEventForm: View {
    enum Kind {
        case meeting
        case reminder

        var heading: String {
            self == .meeting ? "Schedule a follow-up" : "Add a reminder"
        }

        var submitLabel: String {
            self == .meeting ? "Send invite" : "Add to calendar"
        }
    }

    let item: ActionItem
    let kind: Kind
    let onDone: (_ record: String, _ url: URL?) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var calendar: CalendarService

    @State private var title = ""
    @State private var startsAt = Date()
    @State private var durationMinutes = 30
    @State private var attendees = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var availability: [CalendarPlan.BusyPerson] = []
    @State private var isCheckingAvailability = false
    /// Everyone this Mac can already name with an address — the organization's
    /// directory plus whoever has shared a calendar entry with the user — so an
    /// invite is picked, not typed from memory.
    @State private var contacts: [CalendarPlan.Contact] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: .googleCalendar, size: 12)
                Text(kind.heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                Button("Close", action: onClose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .buttonStyle(.plain)
                    .linkCursor()
            }
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
            HStack(spacing: 10) {
                DatePicker("", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                if kind == .meeting {
                    Picker("", selection: $durationMinutes) {
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
            if kind == .meeting {
                TextField("Invite — type a name, or leave empty for a hold", text: $attendees)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
                    .overlay(alignment: .topLeading) {
                        let matches = CalendarPlan.matches(
                            for: attendees,
                            in: contacts,
                            excluding: invitedEmails
                        )
                        if !matches.isEmpty {
                            contactRows(matches)
                                .offset(y: 32)
                        }
                    }
                    .zIndex(1)
                if let unresolved = CalendarPlan.unresolvedNames(in: attendees) {
                    Text("\(unresolved) — no address yet; pick from the list or type the email.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.warning)
                }
                availabilitySection
            }
            if let sendError {
                Text(sendError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }
            HStack(spacing: 8) {
                Button(isSending ? "Adding…" : kind.submitLabel) {
                    Task { await submit() }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.GlassButton.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassButtonSurface(Capsule(style: .continuous))
                .buttonStyle(.plain)
                .linkCursor()
                .disabled(isSending || title.trimmingCharacters(in: .whitespaces).isEmpty)
                if kind == .meeting, !invitedEmails.isEmpty {
                    Text("Invitations are emailed when you press this.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
        }
        .onAppear {
            title = CalendarPlan.title(for: item, kind: kind)
            startsAt = CalendarPlan.defaultStart(for: kind)
        }
        .task(id: availabilityKey) {
            await checkAvailability()
        }
        .task {
            if organizations.people.isEmpty {
                await organizations.refreshPeople()
            }
            let recent = calendar.meetings(overlapping: DateInterval(
                start: Date().addingTimeInterval(-30 * 24 * 3600),
                duration: 44 * 24 * 3600
            ))
            contacts = CalendarPlan.contacts(
                people: organizations.people.map { ($0.displayName, $0.email) },
                attendees: recent.flatMap(\.attendees).map { ($0.display, $0.email) }
            )
        }
    }

    /// The people the typed fragment could mean, floating under the field so
    /// the form's height never jumps while someone types.
    private func contactRows(_ matches: [CalendarPlan.Contact]) -> some View {
        VStack(spacing: 0) {
            ForEach(matches, id: \.email) { contact in
                Button {
                    attendees = CalendarPlan.completing(attendees, with: contact.email)
                } label: {
                    HStack(spacing: 8) {
                        Image("nc-user")
                            .icon(11)
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(width: 14)
                        Text(contact.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.ink)
                        Text(contact.email)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.Palette.bg)
                .overlay(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.border, lineWidth: 1))
        .shadow(color: Theme.Palette.scrim.opacity(0.35), radius: 14, y: 6)
    }

    // MARK: - Availability

    /// Who the invited emails are, cleaned. The availability check keys on
    /// these plus the day, so retyping a comma does not refetch.
    private var invitedEmails: [String] {
        CalendarPlan.emails(in: attendees)
    }

    private var availabilityKey: String {
        invitedEmails.sorted().joined(separator: ",") + "·" +
            Calendar.current.startOfDay(for: startsAt).timeIntervalSince1970.description
    }

    private var slot: DateInterval {
        DateInterval(start: startsAt, duration: TimeInterval(durationMinutes * 60))
    }

    /// Their calendars' answer for the chosen slot — checked before anything is
    /// sent, so the invite that goes out is one people can actually accept.
    @ViewBuilder private var availabilitySection: some View {
        if kind == .meeting, !invitedEmails.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if isCheckingAvailability {
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.circular).controlSize(.mini)
                        Text("Checking their calendars…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                } else if !availability.isEmpty {
                    ForEach(availability, id: \.email) { person in
                        availabilityLine(person)
                    }
                    if let free = CalendarPlan.nextFreeStart(
                        near: startsAt,
                        duration: slot.duration,
                        people: availability
                    ), !CalendarPlan.conflicted(slot: slot, people: availability).isEmpty {
                        Button("Everyone's free at \(free.formatted(date: .omitted, time: .shortened)) — use it") {
                            startsAt = free
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .buttonStyle(.plain)
                        .linkCursor()
                    }
                }
            }
        }
    }

    private func availabilityLine(_ person: CalendarPlan.BusyPerson) -> some View {
        let clash = person.busy.first { CalendarPlan.overlaps($0, slot) }
        return HStack(spacing: 5) {
            if !person.readable {
                Image("nc-eye-closed").icon(10)
                Text("\(person.email) — couldn't check, not necessarily free")
            } else if let clash {
                Image("nc-triangle-warning").icon(10)
                Text("\(person.email) — busy until \(clash.end.formatted(date: .omitted, time: .shortened))")
            } else {
                Image("nc-circle-check").icon(10)
                Text("\(person.email) — free at this time")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(!person.readable ? Theme.Palette.muted : clash == nil ? Theme.Palette.success : Theme.Palette.warning)
    }

    /// Debounced by the task's own cancellation: the key changes on every
    /// address that completes, and a half-typed "a@x.c" would otherwise send a
    /// request per keystroke. Every write is fenced, so a slow earlier answer
    /// can never land over a newer one.
    private func checkAvailability() async {
        guard kind == .meeting, !invitedEmails.isEmpty else {
            availability = []
            return
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }
        let day = Calendar.current.startOfDay(for: startsAt)
        let emails = invitedEmails
        let result = await integrations.run(
            ActionDelegation.call(action: "check_availability", of: .googleCalendar, arguments: [
                "attendees": emails.joined(separator: ","),
                "starts_at": CalendarPlan.rfc3339(day),
                "ends_at": CalendarPlan.rfc3339(day.addingTimeInterval(24 * 3600))
            ]),
            tool: ActionDelegation.tool(action: "check_availability", of: .googleCalendar)
        )
        guard !Task.isCancelled else { return }
        // A failed check is not an empty one: nothing shown reads as "all
        // free", so a failure is every invitee marked as unreadable.
        let people = CalendarPlan.availability(in: result)
        availability = people.isEmpty
            ? emails.map { CalendarPlan.BusyPerson(email: $0, readable: false, busy: []) }
            : people
    }

    private func submit() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        let arguments = CalendarPlan.arguments(
            title: title,
            startsAt: startsAt,
            durationMinutes: kind == .meeting ? durationMinutes : 30,
            attendees: kind == .meeting ? invitedEmails.joined(separator: ",") : ""
        )
        let result = await integrations.run(
            ActionDelegation.call(action: "create_event", of: .googleCalendar, arguments: arguments),
            tool: ActionDelegation.tool(action: "create_event", of: .googleCalendar)
        )
        isSending = false
        if let failure = IntegrationService.failure(in: result) {
            sendError = failure
            return
        }
        let when = startsAt.formatted(date: .abbreviated, time: .shortened)
        onDone(
            kind == .meeting ? "Follow-up scheduled · \(when)" : "Reminder set · \(when)",
            CalendarPlan.createdEventURL(in: result)
        )
    }
}

/// The calendar form's pure pieces, separate so the wire format and the
/// defaults can be tested without a view.
enum CalendarPlan {
    private struct Created: Decodable {
        let url: String?
    }

    private struct Envelope: Decodable {
        let result: Created?
    }

    /// The event's own page out of `create_event`'s answer, so the line that
    /// says "scheduled" is also the way to look at it.
    static func createdEventURL(in result: String) -> URL? {
        guard let data = result.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Envelope.self, from: data).result?.url
        else { return nil }
        return URL(string: raw)
    }

    /// RFC3339 with the local offset — the server's contract is absolute
    /// times, because the client is the only one who knows the user's clock.
    static func rfc3339(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.string(from: date)
    }

    static func arguments(
        title: String,
        startsAt: Date,
        durationMinutes: Int,
        attendees: String
    ) -> [String: String] {
        var arguments = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "starts_at": rfc3339(startsAt),
            "ends_at": rfc3339(startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)))
        ]
        let invited = attendees.trimmingCharacters(in: .whitespaces)
        if !invited.isEmpty { arguments["attendees"] = invited }
        return arguments
    }

    // MARK: - Availability

    /// One invited person's answer: readable or not, and when they are busy.
    struct BusyPerson: Equatable {
        let email: String
        let readable: Bool
        let busy: [DateInterval]
    }

    private enum BusyBlockKeys: String, CodingKey {
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    private struct BusyBlock: Decodable {
        let startsAt: String?
        let endsAt: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: BusyBlockKeys.self)
            startsAt = try container.decodeIfPresent(String.self, forKey: .startsAt)
            endsAt = try container.decodeIfPresent(String.self, forKey: .endsAt)
        }
    }

    private struct PersonRow: Decodable {
        let email: String
        let readable: Bool
        let busy: [BusyBlock]
    }

    private struct AvailabilityPayload: Decodable {
        let people: [PersonRow]
    }

    private struct AvailabilityEnvelope: Decodable {
        let result: AvailabilityPayload?
    }

    /// One person an invite can name: how they read, and the address that
    /// actually goes on the event.
    struct Contact: Equatable {
        let name: String
        let email: String
    }

    /// The directory and the calendar's own attendees, merged by address. A
    /// name from the directory outranks a bare address from an invitation.
    static func contacts(
        people: [(name: String?, email: String?)],
        attendees: [(display: String, email: String?)]
    ) -> [Contact] {
        var byEmail: [String: Contact] = [:]
        for attendee in attendees {
            guard let email = attendee.email?.lowercased(), email.contains("@") else { continue }
            let display = attendee.display.trimmingCharacters(in: .whitespaces)
            byEmail[email] = Contact(name: display.isEmpty ? email : display, email: email)
        }
        for person in people {
            guard let email = person.email?.lowercased(), email.contains("@") else { continue }
            let name = person.name?.trimmingCharacters(in: .whitespaces) ?? ""
            byEmail[email] = Contact(name: name.isEmpty ? email : name, email: email)
        }
        return byEmail.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The fragment after the last comma — what the person is typing now.
    static func fragment(in attendees: String) -> String {
        (attendees.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Who the fragment could mean, by name or address. Nothing for an empty
    /// fragment — the whole directory under an untouched field is noise — and
    /// nothing already invited.
    static func matches(
        for attendees: String,
        in contacts: [Contact],
        excluding invited: [String],
        limit: Int = 5
    ) -> [Contact] {
        let typed = fragment(in: attendees).lowercased()
        guard !typed.isEmpty else { return [] }
        let already = Set(invited.map { $0.lowercased() })
        return contacts
            .filter { !already.contains($0.email) }
            .filter { $0.email != typed }
            .filter { $0.name.lowercased().contains(typed) || $0.email.contains(typed) }
            .prefix(limit)
            .map { $0 }
    }

    /// Replaces the open fragment with the picked address, keeping everyone
    /// already listed and leaving the field ready for the next name.
    static func completing(_ attendees: String, with email: String) -> String {
        var parts = attendees.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        parts[parts.count - 1] = email
        return parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    /// The addresses in the field, complete ones only, each once. "a@x" is
    /// still being typed; "a@x.com" twice is one guest.
    static func emails(in attendees: String) -> [String] {
        var seen = Set<String>()
        return attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isComplete($0) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Names typed but never turned into an address, joined for one warning
    /// line — they would otherwise vanish from the invite without a word.
    static func unresolvedNames(in attendees: String) -> String? {
        let names = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isComplete($0) }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func isComplete(_ address: String) -> Bool {
        guard !address.contains(" "), let at = address.firstIndex(of: "@") else { return false }
        let domain = address[address.index(after: at)...]
        return at > address.startIndex && domain.contains(".") && !domain.hasSuffix(".")
    }

    static func availability(in result: String) -> [BusyPerson] {
        guard let data = result.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AvailabilityEnvelope.self, from: data).result
        else { return [] }
        return payload.people.map { person in
            BusyPerson(
                email: person.email,
                readable: person.readable,
                busy: person.busy.compactMap { block in
                    guard let start = block.startsAt.flatMap(instant), let end = block.endsAt.flatMap(instant),
                          end > start else { return nil }
                    return DateInterval(start: start, end: end)
                }
            )
        }
    }

    /// RFC3339 as Google writes it, with or without a Z.
    static func instant(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// Half-open overlap. `DateInterval.intersects` counts a shared endpoint,
    /// which made a 14:00–15:00 block "conflict" with a 15:00 start — back-to-
    /// back meetings are the calendar working, not an overlap.
    static func overlaps(_ interval: DateInterval, _ slot: DateInterval) -> Bool {
        interval.start < slot.end && interval.end > slot.start
    }

    /// The readable people whose busy blocks cross the slot. Unreadable ones
    /// are a separate warning, never counted as a conflict — or as free.
    static func conflicted(slot: DateInterval, people: [BusyPerson]) -> [BusyPerson] {
        people.filter { person in
            person.readable && person.busy.contains { overlaps($0, slot) }
        }
    }

    /// The earliest start at or after `near` (on a quarter-hour) where nobody
    /// readable is busy, looking across the rest of the day. Nil when the day
    /// has no such gap — a lie about one would schedule the very overlap this
    /// exists to avoid.
    static func nextFreeStart(
        near: Date,
        duration: TimeInterval,
        people: [BusyPerson],
        stepMinutes: Int = 15
    ) -> Date? {
        let step = TimeInterval(stepMinutes * 60)
        let dayEnd = Calendar.current.startOfDay(for: near).addingTimeInterval(24 * 3600)
        let remainder = near.timeIntervalSince1970.truncatingRemainder(dividingBy: step)
        var candidate = remainder == 0 ? near : near.addingTimeInterval(step - remainder)
        while candidate.addingTimeInterval(duration) <= dayEnd {
            let slot = DateInterval(start: candidate, duration: duration)
            if conflicted(slot: slot, people: people).isEmpty { return candidate }
            candidate = candidate.addingTimeInterval(step)
        }
        return nil
    }

    /// A reminder tomorrow morning; a follow-up at the next round hour.
    static func defaultStart(for kind: CalendarEventForm.Kind, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        if kind == .reminder {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
        let hour = calendar.component(.hour, from: now)
        guard hour < 22 else {
            // Past ten at night the "next round hour" is tonight at eleven or
            // yesterday's midnight; tomorrow morning is what anyone means.
            return defaultStart(for: .reminder, now: now)
        }
        return calendar.date(bySettingHour: hour + 1, minute: 0, second: 0, of: now) ?? now
    }

    static func title(for item: ActionItem, kind: CalendarEventForm.Kind) -> String {
        let short = item.text.count <= 60 ? item.text : String(item.text.prefix(59)) + "…"
        return kind == .reminder ? "Reminder: \(short)" : "Follow-up: \(short)"
    }
}
