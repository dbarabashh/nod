import SwiftUI

/// The next meeting the person is going to, and the rest of the day behind it.
///
/// "Not going" is this Mac's word, not the calendar's: the card moves on to
/// the next entry and the notch stops offering to record this one, but the
/// invitation stays accepted — declining emails the organizer, and that is a
/// write the person confirms in chat, not a button on a card. "Make it a task"
/// is the same word with somewhere to go: the entry stays on the calendar and
/// a copy lands in Google Tasks.
struct TodayMeetingCard: View {
    let occurrence: CalendarOccurrence?
    let lastTime: Meeting?
    let meetingBriefing: RemoteCalendar.MeetingBriefing?
    let rest: [TodayMeetingRow]
    let now: Date
    let taskError: String?
    let onCapture: () -> Void
    let onOpenMeeting: (Meeting) -> Void
    let onSkip: (CalendarOccurrence) -> Void
    let onMakeTask: (CalendarOccurrence) -> Void
    let onClear: (CalendarOccurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let occurrence {
                next(occurrence)
            } else {
                Text("Nothing else you're going to today")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            if !rest.isEmpty {
                SettingsRowDivider(indent: 0).padding(.top, 4)
                SectionLabel(occurrence == nil ? "Today" : "Also today", size: .compact)
                ForEach(rest) { row in
                    laterRow(row)
                }
            }
            if let taskError {
                Text(taskError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    @ViewBuilder
    private func next(_ occurrence: CalendarOccurrence) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(TodayBrief.startLine(for: occurrence, now: now))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.warning)
                Text(occurrence.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if !occurrence.others.isEmpty {
                    Text("With \(occurrence.others.map(\.display).joined(separator: ", "))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image("nc-calendar")
                .icon(14)
                .foregroundStyle(Theme.Palette.muted)
        }
        if let lastTime {
            VStack(alignment: .leading, spacing: 3) {
                Text(meetingBriefing?.summary ?? "Last time: \(TodayBrief.knowledgeLine(for: lastTime))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                Text("From \(lastTime.displayTitle(dateFormatter: Meeting.shortDateFormatter))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        HStack(spacing: 8) {
            GlassPillButton(TodayBrief.captureLabel(for: occurrence), size: .compact, action: onCapture)
                .linkCursor()
            if let lastTime {
                SecondaryPillButton("Open last session") { onOpenMeeting(lastTime) }
            }
            Spacer(minLength: 0)
            answerButtons(for: occurrence, answer: nil)
        }
    }

    private func laterRow(_ row: TodayMeetingRow) -> some View {
        let isMarked = row.answer != nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.occurrence.startsAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMarked ? Theme.Palette.muted : Theme.Palette.ink)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.occurrence.title)
                        .font(.system(size: 12.5, weight: isMarked ? .regular : .medium))
                        .foregroundStyle(isMarked ? Theme.Palette.muted : Theme.Palette.ink)
                        .strikethrough(row.answer == .notGoing)
                        .lineLimit(1)
                    if row.answer == .task {
                        TagPill("Task")
                    }
                }
                if !row.occurrence.others.isEmpty {
                    Text("With \(row.occurrence.others.map(\.display).joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            answerButtons(for: row.occurrence, answer: row.answer)
        }
    }

    @ViewBuilder
    private func answerButtons(for occurrence: CalendarOccurrence, answer: MeetingAttendance.Answer?) -> some View {
        switch answer {
        case .notGoing:
            quietButton("Going after all") { onClear(occurrence) }
        case .task:
            quietButton("Back to meeting") { onClear(occurrence) }
        case nil:
            HStack(spacing: 12) {
                quietButton("Make it a task") { onMakeTask(occurrence) }
                quietButton("Not going") { onSkip(occurrence) }
            }
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

/// One entry of the rest of the day, with the person's answer for it.
struct TodayMeetingRow: Identifiable, Equatable {
    let occurrence: CalendarOccurrence
    let answer: MeetingAttendance.Answer?

    var id: String {
        MeetingAttendance.fingerprint(occurrence)
    }
}

/// Beat results delivered here rather than waiting on the Beats page.
struct TodayBeatsCard: View {
    let reports: [TodayView.BeatReportRow]
    let onOpenReport: (TodayView.BeatReportRow) -> Void
    @EnvironmentObject private var analytics: ProductAnalytics

    var body: some View {
        TodayCardList(title: "From your beats", items: reports, row: beatRow)
    }

    private func beatRow(_ row: TodayView.BeatReportRow) -> some View {
        Button {
            TodayBrief.markSeen(row.run, of: row.beat)
            analytics.record(.beatReportOpened, properties: .init(surface: .home, detail: BeatStore.detail(of: row.beat.cadence)))
            onOpenReport(row)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image("nc-stopwatch")
                    .icon(13)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.beat.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.ink)
                        if row.isNew {
                            Text("New")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.Palette.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Theme.Palette.brand))
                        }
                    }
                    if !row.preview.isEmpty {
                        Text(row.preview)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image("nc-chevron-right")
                    .icon(9)
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open in Beats")
    }
}
