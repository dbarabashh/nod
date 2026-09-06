import SwiftUI

/// One beat, opened: the report it last wrote, and the runs before it.
///
/// The report is the page, not a preview behind a button — a beat exists to be
/// read, and the schedule that produced it is a caption. The rail on the right
/// is what makes "read the last one" and "read the one from Tuesday" the same
/// gesture.
struct BeatDetailView: View {
    @EnvironmentObject private var beats: BeatStore
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var runner: BeatRunner

    let beat: Beat
    let onBack: () -> Void
    /// Continues the report as a conversation, in Ask Nod.
    let onOpenThread: (UUID) -> Void
    let onEdit: () -> Void
    /// The run to land on when nothing has been picked yet — the one whose
    /// report the person came here for.
    var focusRunID: UUID?

    @State private var selectedRun: BeatRun?
    @State private var isRunning = false

    private var runs: [BeatRun] {
        beats.runs(of: beat.id)
    }

    private var shown: BeatRun? {
        selectedRun ?? runs.first { $0.id == focusRunID } ?? runs.first { $0.status == .done } ?? runs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            HStack(alignment: .top, spacing: 0) {
                report
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Theme.Palette.border)
                rail
                    .frame(width: 232, alignment: .leading)
            }
        }
        .task(id: shown?.id) {
            guard let run = shown else { return }
            // Read here counts as read: Today's "New" badge and its attention
            // count were only ever cleared by opening the report from Today.
            if run.status == .done {
                TodayBrief.markSeen(run, of: beat)
                analytics.record(.beatReportOpened, properties: .init(surface: .beats, detail: BeatStore.detail(of: beat.cadence)))
            }
            await beats.loadReport(for: run)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image("nc-chevron-left")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .linkCursor()
            VStack(alignment: .leading, spacing: 2) {
                Text(beat.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(BeatSchedule.describe(beat))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
            }
            Spacer(minLength: 12)
            Button(action: onEdit) {
                Image("nc-gear-2")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.7))
            }
            .buttonStyle(.plain)
            .linkCursor()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var report: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if let run = shown {
                    Text(Self.stamp(run.scheduledFor))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    if let text = beats.reports[run.id] {
                        AnswerPieces(pieces: AnswerBlocks
                            .complete(in: text, isFinished: true)
                            .enumerated()
                            .flatMap { AnswerPiece.pieces(from: $0.element, at: $0.offset) })
                    } else {
                        Text(Self.placeholder(for: run))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    }
                } else {
                    Text("This beat hasn't run yet. It will at its next hour, or press Run now.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: runNow) {
                Text(isRunning ? "Running…" : "Run now")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .glassButtonSurface(RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRunning)

            // A report is worth arguing with — "why is that blocking?", "draft
            // the reply" — and that conversation is the thread it was written
            // into. As a text link in the header nobody found it.
            if let threadID = shown?.threadID {
                Button { onOpenThread(threadID) } label: {
                    HStack(spacing: 5) {
                        Image("nc-msg-writing").icon(10)
                        Text("Open in chat")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(Theme.Palette.surfaceStrong)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                    .stroke(Theme.Palette.border, lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .linkCursor()
                Text("Ask about this report and keep going.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !runs.isEmpty {
                SectionLabel("History")
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(runs) { run in
                            runRow(run)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    private func runRow(_ run: BeatRun) -> some View {
        let isSelected = shown?.id == run.id
        return Button {
            selectedRun = run
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.stamp(run.scheduledFor))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                Text(Self.summary(of: run, report: beats.reports[run.id]))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(isSelected ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    private func runNow() {
        isRunning = true
        Task {
            defer { isRunning = false }
            guard await beats.runNow(beat.id) != nil else { return }
            // Don't wait out the poll: the person is looking at the screen.
            await runner.answerDueNow()
            await beats.refresh()
            selectedRun = nil
        }
    }

    /// What stands in for a report that isn't there to show.
    static func placeholder(for run: BeatRun) -> String {
        switch run.status {
        case .done: "Loading the report…"
        case .due, .claimed: "Nod is writing this one now."
        case .failed: run.error ?? "This run failed."
        case .expired: "Missed — this Mac was asleep when it came due."
        case .unknown: "Nothing to show for this run."
        }
    }

    /// "Today, 3:06 PM" — the reference format, and the one a person uses to
    /// tell two mornings apart.
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.setLocalizedDateFormatFromTemplate("j:mm")
        let clock = time.string(from: date)
        if calendar.isDateInToday(date) { return "Today, \(clock)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(clock)" }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return "\(day.string(from: date)), \(clock)"
    }

    /// The rail's one line per run: the report's opening heading when there is
    /// one, and what went wrong when there isn't.
    static func summary(of run: BeatRun, report: String?) -> String {
        switch run.status {
        case .done:
            let headline = report.map { BeatRun.headline(of: $0) } ?? ""
            return headline.isEmpty ? "Report" : headline
        case .failed: return run.error ?? "Failed"
        case .expired: return "Missed — this Mac was asleep"
        case .due, .claimed: return "Running now…"
        case .unknown: return ""
        }
    }
}

#if DEBUG
    #Preview("Beat detail") {
        BeatDetailView(
            beat: Beat(
                id: UUID(),
                userID: UUID(),
                title: "Morning brief",
                prompt: "What does my day look like?",
                cadence: .weekdays,
                hour: 9,
                minute: 0,
                weekday: 1,
                dayOfMonth: 1,
                timezone: "Europe/Lisbon",
                enabled: true,
                nextRunAt: nil,
                createdAt: nil
            ),
            onBack: {},
            onOpenThread: { _ in },
            onEdit: {}
        )
        .environmentObject(BeatStore(supabase: nil, auth: nil))
        .environmentObject(ProductAnalytics.preview)
        .frame(width: 900, height: 560)
        .background(Theme.Palette.bg)
    }
#endif
