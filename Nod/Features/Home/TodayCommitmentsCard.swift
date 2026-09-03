import SwiftUI

/// The "Waiting on you" list. Its own view because a row is now a small
/// machine — checkbox, in-place drawer, delegate form — and the home surface
/// reads better without owning its plumbing.
struct TodayCommitmentsCard: View {
    /// Every open commitment, uncapped — how many of them actually render is
    /// this view's own call (`shown`), not the caller's, so "see all" has
    /// something to reveal without a second round trip to the store.
    let openItems: [ActionItem]
    let ambientHints: [UUID: [ScreenObservation]]
    @Binding var expandedItemID: UUID?
    let onAsk: (String) -> Void
    let onOpenMeeting: (Meeting) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore

    @State private var showAll = false

    private static let rowLimit = 4

    private var shown: [ActionItem] {
        showAll ? openItems : Array(openItems.prefix(Self.rowLimit))
    }

    private var hiddenCount: Int {
        max(0, openItems.count - Self.rowLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TodayCardList(title: "Waiting on you", items: shown) { item in
                row(item)
                    // The drawer's pickers float out of their row; without
                    // this the rows below, drawn later, paint over them.
                    .zIndex(expandedItemID == item.id ? 1 : 0)
            }
            if hiddenCount > 0 {
                Button {
                    showAll.toggle()
                } label: {
                    Text(showAll ? "Show less" : "See \(hiddenCount) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .padding(.leading, 2)
            }
        }
    }

    private func meta(for item: ActionItem) -> some View {
        HStack(spacing: 6) {
            if let deadline = item.deadline {
                Text(deadline)
            }
            // The source is a reference, not an action: a plain tappable line,
            // so opening evidence never competes with acting on the item.
            if let meeting = meetingStore.byID[item.meetingID] {
                Button {
                    onOpenMeeting(meeting)
                } label: {
                    HStack(spacing: 3) {
                        Text(meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter))
                            .lineLimit(1)
                        Image("nc-arrow-up-right").icon(8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Open the source session")
            }
            if let filed = item.filed {
                ProviderLink(item: filed, style: .compact)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.Palette.muted)
    }

    private func row(_ item: ActionItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    Task { await actionItemStore.setDone(!item.done, itemID: item.id) }
                } label: {
                    ActionCheckbox(done: item.done)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help(item.done ? "Reopen" : "Mark done")

                // The click opens the actions, in place. The session is
                // evidence — reachable below as Open source — not where a
                // task's click should land.
                Button {
                    expandedItemID = expandedItemID == item.id ? nil : item.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        meta(for: item)
                        if let hint = ambientHints[item.id]?.first {
                            HStack(spacing: 5) {
                                Image("nc-window-pointer").icon(10)
                                Text("Looks like you worked on this — \(hint.appDisplayName): \(hint.sourceTitle)")
                                    .lineLimit(1)
                                Text("· Ambient · Private")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.cyan)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if expandedItemID == item.id {
                ActionItemDrawer(
                    item: item,
                    sourceTitle: meetingStore.byID[item.meetingID]?
                        .displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    ambientHints: ambientHints[item.id] ?? [],
                    onAsk: onAsk,
                    onOpenSource: {
                        if let meeting = meetingStore.byID[item.meetingID] { onOpenMeeting(meeting) }
                    }
                )
                .padding(.leading, 44)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }
}

/// Handed-over commitments: quieter, uncounted, closable when the thread comes
/// back done.
struct TodayWaitingOnOthersCard: View {
    let items: [ActionItem]

    @EnvironmentObject private var actionItemStore: ActionItemStore

    var body: some View {
        TodayCardList(title: "Waiting on others", items: items, row: row)
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                Task {
                    await actionItemStore.setDone(!item.done, itemID: item.id)
                    ActionDelegation.forget(item.id)
                }
            } label: {
                ActionCheckbox(done: item.done)
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Close it — the thread came back done")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let record = ActionDelegation.recorded(for: item.id) {
                    Text(record)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
