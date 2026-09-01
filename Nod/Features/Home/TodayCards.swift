import SwiftUI

/// The next meeting, with what last time with these people left open, and
/// the one button that starts it.
struct TodayMeetingCard: View {
    let occurrence: CalendarOccurrence
    let lastTime: Meeting?
    let now: Date
    let onCapture: () -> Void
    let onOpenMeeting: (Meeting) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text("Last time: \(TodayBrief.knowledgeLine(for: lastTime))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    Text("From \(lastTime.displayTitle(dateFormatter: Meeting.shortDateFormatter))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            HStack(spacing: 8) {
                Button(TodayBrief.captureLabel(for: occurrence), action: onCapture)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .buttonStyle(.plain)
                    .linkCursor()
                if let lastTime {
                    Button("Open last session") { onOpenMeeting(lastTime) }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
                        .buttonStyle(.plain)
                        .linkCursor()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }
}

/// Beat results delivered here rather than waiting on the Beats page.
struct TodayBeatsCard: View {
    let reports: [TodayView.BeatReportRow]
    let onOpenBeats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("From your beats")
            VStack(spacing: 0) {
                ForEach(Array(reports.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().overlay(Theme.Palette.border).padding(.leading, 44)
                    }
                    beatRow(row)
                }
            }
            .surfaceCard()
        }
    }

    private func beatRow(_ row: TodayView.BeatReportRow) -> some View {
        Button {
            TodayBrief.markSeen(row.run, of: row.beat)
            onOpenBeats()
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
