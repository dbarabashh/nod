import SwiftUI

/// What a session is, said in one row: when it happened, who can see it, what
/// language Nod wrote it in.
///
/// It replaces a label-and-value grid — "Created", "Duration", "Nod language",
/// each on its own line with an 84pt gutter. The grid read as a form, and a
/// form is a thing you fill in; none of this is. More to the point, the two
/// facts a person actually checks on opening a session — *is this only mine*
/// and *is this the right meeting* — were not in it at all. The first was three
/// clicks away under Share, the second nowhere.
///
/// So each fact is a chip, each chip that can be changed opens where it is, and
/// the two that answer a question about the session lead.
///
/// One row, not two. The projects pill used to sit on a line of its own above
/// this, in the same shape and the same size — which read as one row of chips
/// broken in half, and left a person adding a project to a session watching the
/// wrong row for it to appear in.
struct MeetingDetailChips: View {
    let meeting: Meeting
    let isUnsynced: Bool
    /// False until the row is on the server. Sharing and linking both address a
    /// meeting by id, so neither can be offered before one exists.
    let isReady: Bool

    var body: some View {
        HStack(spacing: Theme.Space.x2) {
            CalendarLinkChip(meeting: meeting, isReady: isReady)
            MeetingAccessChip(meetingID: meeting.id, isReady: isReady)
            if isReady { MeetingProjectChip(meetingID: meeting.id) }
            languageChip
            if isUnsynced { syncChip }
            Spacer(minLength: 0)
        }
    }

    /// Not a control. The language a session was written in is decided before
    /// it runs and cannot be changed afterwards without regenerating, so this
    /// says what happened rather than offering to change it.
    private var languageChip: some View {
        MeetingChipSurface(isInteractive: false) {
            Text(meeting.language.uppercased())
                .textStyle(Theme.Typography.micro)
                .tracking(0.5)
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
        }
        .help("Nod wrote this session in \(meeting.language.uppercased())")
    }

    /// Only while the session is still queued in the durable outbox. The recap
    /// is safe on this device; this says why it isn't on the server yet.
    private var syncChip: some View {
        MeetingChipSurface(isInteractive: false, tint: Theme.Palette.warning) {
            HStack(spacing: Theme.Space.x1) {
                Image("nc-refresh-2").icon(Theme.Control.iconMicro)
                Text("Syncing")
                    .textStyle(Theme.Typography.meta.weight(.medium))
            }
            .foregroundStyle(Theme.Palette.warning)
        }
        .help("Saved on this device — syncing")
    }
}

// MARK: - The chip

/// One pill, so every chip in the row is the same object at the same size.
///
/// `isInteractive` is what separates a fact from a control, and it has to be
/// visible standing still. Hover was not enough: a person reads the row before
/// their cursor is anywhere near it, and a chip that only reveals itself when
/// touched is one they never touch. So an openable chip carries the chevron
/// this app already uses to mean "there is more here" — drawn here rather than
/// at each call site, so a chip cannot be interactive and fail to say so.
struct MeetingChipSurface<Content: View>: View {
    var isInteractive = true
    var tint: Color?
    @ViewBuilder let content: Content

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.x1) {
            content
            if isInteractive {
                Image("nc-chevron-down")
                    .icon(7)
                    .foregroundStyle(Theme.Palette.muted.opacity(isHovering ? 1 : 0.65))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.x2)
        .padding(.vertical, Theme.Space.x1)
        .frame(minHeight: Theme.Control.heightCompact - Theme.Space.x2)
        .background(
            Capsule(style: .continuous)
                .fill(fill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(stroke, lineWidth: 0.5)
                )
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovering = isInteractive && $0 }
    }

    private var fill: Color {
        guard let tint else {
            return isHovering ? Theme.Palette.surfaceStrong : Theme.Palette.surface
        }
        return tint.opacity(0.12)
    }

    private var stroke: Color {
        guard let tint else {
            return isInteractive ? Theme.Palette.border : .clear
        }
        return tint.opacity(0.35)
    }
}

// MARK: - What it is filed under

/// The projects a session is filed under, and the picker that changes them.
///
/// Lives in the chip row rather than on a line of its own: it is the same kind
/// of fact as the two beside it, and a row of pills split across two lines is a
/// row somebody has to scan twice.
struct MeetingProjectChip: View {
    let meetingID: UUID

    @EnvironmentObject private var labelStore: LabelStore
    @State private var isPicking = false

    var body: some View {
        let assigned = labelStore.labels(for: meetingID)
        Button { isPicking = true } label: {
            MeetingChipSurface {
                HStack(spacing: Theme.Space.x1) {
                    Image("nc-tag").icon(Theme.Control.iconMicro)
                    if assigned.isEmpty {
                        Text("Add to project")
                            .textStyle(Theme.Typography.meta.weight(.medium))
                    } else {
                        Text("In")
                            .textStyle(Theme.Typography.meta)
                            .foregroundStyle(Theme.Palette.muted)
                        // Named, not counted, for the same reason the access
                        // chip names its audience: "2 projects" is a number
                        // somebody then has to open the picker to read.
                        ForEach(assigned) { label in
                            HStack(spacing: Theme.Space.x1) {
                                Circle()
                                    .fill(label.swatchColor)
                                    .frame(width: 6, height: 6)
                                Text(label.name)
                                    .textStyle(Theme.Typography.meta.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .foregroundStyle(assigned.isEmpty ? Theme.Palette.muted : Theme.Palette.ink.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Add or remove projects")
        .dismissWhenMoved($isPicking)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            LabelPickerPopover(meetingID: meetingID)
        }
    }
}

// MARK: - When it happened

/// The session's time, and the calendar entry behind it when there is one.
///
/// Opening it offers that day's entries. The automatic match is the server's
/// and always wins; this is for the session it never identified — which is the
/// only session anybody opens a picker for.
struct CalendarLinkChip: View {
    let meeting: Meeting
    let isReady: Bool

    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var meetingStore: MeetingStore
    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            MeetingChipSurface {
                HStack(spacing: Theme.Space.x1) {
                    Image("nc-calendar-days").icon(Theme.Control.iconMicro)
                    Text(label)
                        .textStyle(Theme.Typography.meta.weight(.medium))
                    Text(Self.duration(from: meeting.startedAt, to: meeting.endedAt))
                        .textStyle(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.muted)
                }
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.4)
        .linkCursor()
        .help(linked == nil ? "Link this to a calendar event" : "Change the calendar event")
        .dismissWhenMoved($isPicking)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            CalendarLinkPopover(
                meeting: meeting,
                occurrences: candidates,
                isWidened: isWidened,
                onPick: link
            )
        }
    }

    /// The entry this session is already pointed at, when that entry is still
    /// on the calendar. A link to something deleted is a link to nothing, and
    /// showing its stale title would be the one thing worse than showing none.
    private var linked: CalendarOccurrence? {
        guard let icalUID = meeting.icalUID else { return nil }
        return candidates.first { $0.externalID == icalUID }
    }

    /// The day the session ran, widened until there is a list worth reading.
    ///
    /// A day with two entries on it is not a picker, and the right entry is
    /// often not on the day at all: a call that ran past midnight, or an
    /// invitation whose time was moved after the fact. So the window opens at
    /// the day and steps outwards only while it has too little to offer.
    private var candidates: [CalendarOccurrence] {
        for days in Self.windows {
            let found = occurrences(withinDays: days)
            if found.count >= Self.wanted || days == Self.windows.last { return found }
        }
        return []
    }

    /// How many entries make a list rather than a fragment.
    private static let wanted = 4
    /// Days either side of the session, tried in order. It stops at a week —
    /// past that the entry a person is looking for is not "near" this session
    /// in any sense they would recognise.
    private static let windows = [0, 1, 7]

    private func occurrences(withinDays days: Int) -> [CalendarOccurrence] {
        let calendarDay = Calendar.current.startOfDay(for: meeting.startedAt)
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: calendarDay),
              let end = Calendar.current.date(byAdding: .day, value: days + 1, to: calendarDay)
        else { return [] }
        let found = calendar.meetings(overlapping: DateInterval(start: start, end: end))
        // One invitation, one row. `CalendarService.merged` drops a synced copy
        // that a local calendar already has, but says nothing about two local
        // ones — and an invitation sitting in both a personal and a work
        // account is the ordinary case, not an edge. It showed as the same
        // meeting listed twice, both ticked.
        var seen: Set<String> = []
        return found
            .filter { occurrence in
                guard let externalID = occurrence.externalID else { return true }
                return seen.insert(externalID).inserted
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// Whether the list reaches past the session's own day, so the popover can
    /// say so rather than letting a neighbouring day read as that day's.
    private var isWidened: Bool {
        occurrences(withinDays: 0).count < Self.wanted
    }

    private var label: String {
        linked?.title ?? Self.dayFormatter.string(from: meeting.startedAt)
    }

    private func link(_ occurrence: CalendarOccurrence?) {
        isPicking = false
        Task {
            try? await meetingStore.link(meeting.id, toCalendarEvent: occurrence?.externalID)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }
        return String(format: "%dm", minutes)
    }
}

/// That day's calendar, with the linked entry ticked.
///
/// Built to the shape `LabelPickerPopover` already set: a field to narrow the
/// list, a divider, rows that tick when chosen. Two pickers in one header that
/// open onto different-looking lists teach a person nothing except that the app
/// was written by two people.
private struct CalendarLinkPopover: View {
    let meeting: Meeting
    let occurrences: [CalendarOccurrence]
    /// True when the list reaches past the session's own day, because the day
    /// alone had too little on it.
    let isWidened: Bool
    let onPick: (CalendarOccurrence?) -> Void

    @State private var query = ""
    @State private var hovering: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [CalendarOccurrence] {
        guard !trimmedQuery.isEmpty else { return occurrences }
        return occurrences.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// Four rows, whatever the day holds. A list that shrink-wraps to two
    /// entries reads as "that is all there is" on a day that had eight, and a
    /// picker whose height changes with its contents gives no sense of how much
    /// is below the fold.
    private static let visibleRows = 4
    /// Icon and two lines of text, plus the row's own padding.
    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            // The day, said out loud. The list is that day's calendar and
            // nothing else, and a search field with no scope reads as though it
            // searches everything — so somebody typing a meeting from last week
            // would conclude Nod could not find it.
            SectionLabel(
                isWidened
                    ? "Around \(Self.dayFormatter.string(from: meeting.startedAt))"
                    : Self.dayFormatter.string(from: meeting.startedAt)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.x3)
            .padding(.top, Theme.Space.x3)
            TextField("Find an event", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(Theme.Space.x2)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered, id: \.startsAt) { row($0) }
                    if meeting.icalUID != nil, trimmedQuery.isEmpty {
                        unlinkRow
                    }
                    if filtered.isEmpty {
                        Text(occurrences.isEmpty ? "Nothing on your calendar that week" : "No matching event")
                            .textStyle(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.x3)
                    }
                }
            }
            .frame(
                minHeight: min(CGFloat(max(filtered.count, 1)), CGFloat(Self.visibleRows)) * Self.rowHeight,
                maxHeight: CGFloat(Self.visibleRows) * Self.rowHeight
            )
        }
        .frame(width: 264)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()

    private func row(_ occurrence: CalendarOccurrence) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image("nc-calendar-days")
                .icon(Theme.Control.iconMicro)
                .foregroundStyle(Theme.Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(occurrence.title)
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(when(occurrence))
                    .textStyle(Theme.Typography.meta)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
            if isLinked(occurrence) {
                Image("nc-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.violet)
            }
        }
        .padding(.horizontal, Theme.Space.x3)
        .padding(.vertical, Theme.Space.x2)
        .contentShape(Rectangle())
        .onTapGesture { onPick(occurrence) }
        .onHover { if $0 { hovering = occurrence.startsAt } else if hovering == occurrence.startsAt { hovering = nil } }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: hovering)
    }

    /// Only when there is a link to break. An offer to unlink nothing is a row
    /// that does nothing, which is worse than one less row.
    private var unlinkRow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.x2) {
                Image("nc-xmark")
                    .icon(Theme.Control.iconMicro)
                    .foregroundStyle(Theme.Palette.muted)
                Text("Not from my calendar")
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.x2)
            .contentShape(Rectangle())
            .onTapGesture { onPick(nil) }
        }
    }

    /// The time on the session's own day, the date and time on any other. A
    /// bare "12:00" on a row from the day before reads as this day's noon.
    private func when(_ occurrence: CalendarOccurrence) -> String {
        let time = Self.timeFormatter.string(from: occurrence.startsAt)
        guard !Calendar.current.isDate(occurrence.startsAt, inSameDayAs: meeting.startedAt) else {
            return time
        }
        return "\(Self.shortDayFormatter.string(from: occurrence.startsAt)) · \(time)"
    }

    private func isLinked(_ occurrence: CalendarOccurrence) -> Bool {
        occurrence.externalID != nil && occurrence.externalID == meeting.icalUID
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()
}

// MARK: - Who can see it

/// Who this session is visible to, on the session.
///
/// The state it exists to show is the quiet one: **Me**. A person opening a
/// recording of a call about pay, or a one-to-one, wants that answered without
/// asking, and until now nothing on the screen answered it — the only trace of
/// sharing was under a Share menu, which says what you *can* do rather than
/// what is *already true*.
///
/// The audience is a team, never a person, for the reason `MeetingShareButton`
/// gives: a grant written per-person changes meaning every time the roster
/// does. So this chip names teams, and "Me" is simply the absence of any.
struct MeetingAccessChip: View {
    let meetingID: UUID
    let isReady: Bool

    @EnvironmentObject private var grants: MeetingGrantStore
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var labelStore: LabelStore
    @State private var isPicking = false

    var body: some View {
        if let orgID = organizations.activeOrgID, let membership = organizations.activeMembership {
            let teams = organizations.teams(in: orgID)
            let audience = audience(teams: teams, orgName: membership.organization.name)
            Button { isPicking = true } label: {
                MeetingChipSurface {
                    content(title: audience.title, isShared: !audience.isPrivate)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.4)
            .linkCursor()
            // Asked when the answer is read, not only when the app came
            // forward. Grants are pulled at sign-in and on activation, so a
            // session shared from another Mac — or before this launch — read
            // as "Only me" until something unrelated woke the app. That was
            // survivable while sharing state lived behind a Share menu; it is
            // not survivable now that the row states it outright.
            .task(id: meetingID) { await grants.refresh() }
            .dismissWhenMoved($isPicking)
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                MeetingSharePicker(
                    meetingID: meetingID,
                    teams: teams,
                    existing: grants.grants(forMeeting: meetingID),
                    orgID: orgID,
                    orgName: membership.organization.name,
                    viaProjects: audience.viaProjects
                )
            }
        } else {
            // Nobody to share with, so the chip states the fact and offers
            // nothing — a control that opens onto an empty list is a question
            // with no answer.
            MeetingChipSurface(isInteractive: false) {
                content(title: "Only me", isShared: false)
            }
            .help("This session is visible only to you")
        }
    }

    /// Both routes a person controls: a grant on the session, and a project it
    /// is filed in that somebody shared. Counting only the first is how a
    /// session inside a shared project came to read "Only me".
    private func audience(teams: [Team], orgName: String) -> MeetingAudience {
        MeetingAudience.of(
            grants: grants.grants(forMeeting: meetingID),
            projects: labelStore.labels(for: meetingID).map {
                (name: $0.name, shares: labelStore.shares[$0.id] ?? [])
            },
            teams: teams.map { (id: $0.id, name: $0.name) },
            orgName: orgName
        )
    }

    private func content(title: String, isShared: Bool) -> some View {
        HStack(spacing: Theme.Space.x1) {
            Image(isShared ? "nc-users" : "nc-lock")
                .icon(Theme.Control.iconMicro)
            Text(title)
                .textStyle(Theme.Typography.meta.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(isShared ? Theme.Palette.ink.opacity(0.9) : Theme.Palette.muted)
    }
}
