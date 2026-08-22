import SwiftUI

/// The screen you open at the start of the day.
///
/// A briefing rather than a list: it greets you by the actual hour, says in
/// prose what today is made of, and puts the one fixed thing in front of you
/// before anything you could merely look up. The rows underneath are what the
/// prose is about, kept quiet so they read as its evidence.
struct DailyBriefingView: View {
    let onOpenMeeting: (UUID) -> Void
    let onOpenActions: () -> Void

    @EnvironmentObject private var briefings: DailyBriefingStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                greeting
                if briefings.facts.isEmpty {
                    quietDay
                } else {
                    brief
                    lead
                    rest
                    reviewAll
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await briefings.refresh() }
        // The digest key rather than the array: `Meeting` is `Equatable` over
        // its whole summary and recap tree, and a forced refresh installs a
        // freshly decoded array on every activation, so comparing the list
        // memcmps every summary on the main actor.
        .onChange(of: meetingStore.digestKey) { _ in briefings.rebuild() }
        .onChange(of: actionItemStore.revision) { _ in briefings.rebuild() }
    }

    // MARK: - Header

    /// Only the greeting ages, and only across four hour boundaries — so the
    /// minute tick wraps these two lines rather than the screen. Ticking the
    /// whole body re-ran the row builders once a minute to redraw nothing.
    private var greeting: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    DailyBriefing.greeting(
                        name: Profile.firstName(in: profileStore.profile?.displayName),
                        now: context.date
                    )
                )
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                Text(ChatHomeSuggestions.dayLine(context.date))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    /// The centrepiece. Set at reading size rather than caption size, because
    /// it is the part meant to be read rather than scanned.
    @ViewBuilder private var brief: some View {
        if let written = briefings.brief, !written.isEmpty {
            Text(written)
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else if briefings.isWriting {
            ThreeBalls()
                .frame(height: 22, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quietDay: some View {
        Text("Nothing on the calendar, nothing owed, and nothing a recent session left open.")
            .font(.system(size: 14.5))
            .lineSpacing(4)
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The rows

    @ViewBuilder private var lead: some View {
        if let row = briefings.facts.lead {
            DailyBriefingLead(row: row, onOpen: onOpenMeeting)
        }
    }

    private var rest: some View {
        let remaining = briefings.facts.rest
        return VStack(alignment: .leading, spacing: 18) {
            group("Later today", rows: remaining.ahead)
            group("Still owed", rows: remaining.owed)
            group("Left unresolved", rows: remaining.loose)
        }
    }

    @ViewBuilder
    private func group(_ title: String, rows: [DailyBriefing.Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(title)
                    .padding(.bottom, 4)
                ForEach(rows) { row in
                    DailyBriefingRow(row: row, onOpen: onOpenMeeting)
                }
            }
        }
    }

    /// The briefing shows what today needs, which is deliberately fewer items
    /// than the account holds. This is the way through to all of them.
    @ViewBuilder private var reviewAll: some View {
        if !briefings.facts.owed.isEmpty {
            GlassActionButton(title: "Review every open action", action: onOpenActions)
        }
    }
}

/// The one row with a border around it: the next fixed thing in the day.
private struct DailyBriefingLead: View {
    let row: DailyBriefing.Row
    let onOpen: (UUID) -> Void

    var body: some View {
        Button {
            row.meetingID.map(onOpen)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.kind == .ahead ? "Next up" : "First thing")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.Palette.brand)
                    Text(row.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(emphasis: .strong)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.meetingID == nil)
    }

    /// A countdown while one is meaningful, the clock time once it isn't, and
    /// the deadline for anything that isn't a calendar entry at all. Only this
    /// label ages, so only this label is inside the tick.
    @ViewBuilder private var trailing: some View {
        if let startsAt = row.startsAt {
            TimelineView(.everyMinute) { context in
                label(DailyBriefing.countdown(to: startsAt, from: context.date) ?? row.meta)
            }
        } else {
            label(row.meta)
        }
    }

    @ViewBuilder
    private func label(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize()
        }
    }
}

/// A quiet line, not a card. Giving every row the lead's weight is what turned
/// this screen into the list it is supposed to replace.
private struct DailyBriefingRow: View {
    let row: DailyBriefing.Row
    let onOpen: (UUID) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            row.meetingID.map(onOpen)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let meta = row.meta {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .hoverHighlight(isHovering, cornerRadius: Theme.Radii.chip, reduceMotion: reduceMotion)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.meetingID == nil)
        .linkCursor()
        .onHover { isHovering = $0 && row.meetingID != nil }
    }
}
