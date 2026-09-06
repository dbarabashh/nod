import SwiftUI

/// The "Waiting on you" list. Its own view because a row is now a small
/// machine — checkbox, in-place drawer, delegate form — and the home surface
/// reads better without owning its plumbing.
///
/// A row has to say it can be opened before it is hovered: `linkCursor` is a
/// no-op below macOS 15, so on macOS 13 and 14 the pointer alone gives no
/// affordance at all. Hence the chevron at rest.
struct TodayCommitmentsCard: View {
    /// Every open commitment, uncapped. How many render before "see more" is
    /// this view's own call (`shown`), so the reveal costs no round trip.
    let openItems: [ActionItem]
    let ambientHints: [UUID: [ScreenObservation]]
    @Binding var expandedItemID: UUID?
    let onAsk: (ActionDelegation.AskRequest) -> Void
    let onOpenMeeting: (Meeting) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var integrations: IntegrationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAll = false
    @State private var hoveredItemID: UUID?
    /// Rows ticked but not yet gone. The store drops a done item from
    /// `openItems` at once, which read as the row vanishing under the click;
    /// the tick shows for a beat first, and a second click in that beat undoes it.
    @State private var settling: [UUID: Task<Void, Never>] = [:]
    @State private var collapsedGroupIDs: Set<UUID> = []
    /// The outcome a context menu named, so picking "Schedule a follow-up" from
    /// the right-click opens that form rather than the menu it sits in.
    @State private var preselected: Preselection?

    /// `token` is what makes a second pick of the same outcome on the same row
    /// land: the drawer seeds its intent from `State(initialValue:)`, which is
    /// read once per view identity, so re-opening a form the person cancelled
    /// needs a new identity rather than a new value.
    private struct Preselection: Equatable {
        let itemID: UUID
        let intent: ActionIntent
        var token = UUID()
    }

    /// How many commitments the briefing shows before the rest are grouped
    /// behind "see more". Today reads it too, to count what it calls "tracked"
    /// and to decide which items are worth a round trip for their ambient
    /// hints — so a row only reachable by expanding carries none, and shows no
    /// "you worked on this" line even when the person did.
    static let rowLimit = 4

    private var shown: [ActionItem] {
        Array(openItems.prefix(Self.rowLimit))
    }

    private var hiddenCount: Int {
        max(0, openItems.count - Self.rowLimit)
    }

    /// The full list, by the session that produced each item.
    private var groups: [ActionGroup] {
        ActionGrouping.bySession(openItems, meetings: meetingStore.byID)
    }

    private var intents: [ActionIntent] {
        ActionIntent.available(usable: integrations.isUsable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showAll {
                SectionLabel("Waiting on you")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        groupCard(group)
                            .zIndex(group.items.contains { $0.id == expandedItemID } ? 1 : 0)
                    }
                }
            } else {
                TodayCardList(title: "Waiting on you", items: shown) { item in
                    row(item, showsSource: true)
                        // The drawer's pickers float out of their row; without
                        // this the rows below, drawn later, paint over them.
                        .zIndex(expandedItemID == item.id ? 1 : 0)
                }
            }
            if showAll || hiddenCount > 0 {
                revealButton
            }
        }
    }

    private var revealButton: some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) {
                showAll.toggle()
                collapsedGroupIDs = []
                collapse()
            }
        } label: {
            Text(showAll ? "Show less" : "See \(hiddenCount) more")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
        .padding(.leading, 2)
    }

    private func groupCard(_ group: ActionGroup) -> some View {
        VStack(spacing: 0) {
            groupHeader(group)
            if !collapsedGroupIDs.contains(group.id) {
                ForEach(group.items) { item in
                    Divider().overlay(Theme.Palette.border).padding(.leading, 44)
                    row(item, showsSource: false)
                        .zIndex(expandedItemID == item.id ? 1 : 0)
                }
            }
        }
        .surfaceCard()
    }

    private func groupHeader(_ group: ActionGroup) -> some View {
        let isCollapsed = collapsedGroupIDs.contains(group.id)
        return HStack(spacing: 8) {
            Button {
                toggleGroup(group)
            } label: {
                HStack(spacing: 8) {
                    Image("nc-chevron-right")
                        .icon(9)
                        .foregroundStyle(Theme.Palette.muted)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    Spacer(minLength: 8)
                    Text("\(group.items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .padding(.leading, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            // A sibling of the collapse control, never inside its label: this
            // is the only way to the evidence once a grouped row stops
            // carrying its own source line.
            if let meeting = meetingStore.byID[group.id] {
                Button {
                    onOpenMeeting(meeting)
                } label: {
                    Image("nc-arrow-up-right")
                        .icon(9)
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Open the source session")
            }
        }
        .padding(.trailing, 10)
    }

    private func toggleGroup(_ group: ActionGroup) {
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            if collapsedGroupIDs.contains(group.id) {
                collapsedGroupIDs.remove(group.id)
            } else {
                collapsedGroupIDs.insert(group.id)
                if let expandedItemID, group.items.contains(where: { $0.id == expandedItemID }) {
                    collapse()
                }
            }
        }
    }

    /// `showsSource` is false inside a group: the header above already names the
    /// session, and repeating it per row is the noise the grouping removes.
    private func row(_ item: ActionItem, showsSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rowHeader(item, showsSource: showsSource)
            if expandedItemID == item.id {
                let picked = preselected?.itemID == item.id ? preselected : nil
                ActionItemDrawer(
                    item: item,
                    sourceTitle: meetingStore.byID[item.meetingID]?
                        .displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    ambientHints: ambientHints[item.id] ?? [],
                    preselectedIntent: picked?.intent,
                    onAsk: onAsk,
                    onOpenSource: {
                        if let meeting = meetingStore.byID[item.meetingID] { onOpenMeeting(meeting) }
                    },
                    onClose: { collapse() }
                )
                // A fresh token is a fresh identity, which is the only thing
                // that re-seeds the drawer's intent — picking an outcome from
                // the context menu of a row that is already open, or picking
                // the same one twice, would otherwise change nothing.
                .id(picked?.token)
                .padding(.leading, 44)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private func rowHeader(_ item: ActionItem, showsSource: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    toggleDone(item)
                } label: {
                    ActionCheckbox(done: item.done || settling[item.id] != nil)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help(item.done || settling[item.id] != nil ? "Reopen" : "Mark done")

                // The click opens the actions, in place. The session is
                // evidence — reachable as the header's arrow, or the drawer's
                // quote — not where a task's click should land.
                Button {
                    toggle(item)
                } label: {
                    summary(of: item, showsSource: showsSource)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
            trailingControls(item)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // Inset well clear of the card's own 18pt corner, and a step lighter
        // than the default: the rows already sit on a `surfaceCard` fill, and
        // the two together read as a slab rather than a pointer.
        .hoverHighlight(
            hoveredItemID == item.id,
            cornerRadius: 10,
            reduceMotion: reduceMotion,
            inset: CGSize(width: 6, height: 3),
            fill: Theme.Palette.surface
        )
        .onHover { hovering in
            if hovering {
                hoveredItemID = item.id
            } else if hoveredItemID == item.id {
                hoveredItemID = nil
            }
        }
        .contextMenu { menu(for: item) }
    }

    private func summary(of item: ActionItem, showsSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.ink)
                .strikethrough(settling[item.id] != nil, color: Theme.Palette.muted)
                .opacity(settling[item.id] != nil ? 0.55 : 1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            meta(for: item, showsSource: showsSource)
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

    private func toggleDone(_ item: ActionItem) {
        if let pending = settling.removeValue(forKey: item.id) {
            pending.cancel()
            return
        }
        guard !item.done else {
            Task { await actionItemStore.setDone(false, itemID: item.id) }
            return
        }
        settling[item.id] = Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 400 : 900))
            guard !Task.isCancelled else { return }
            await actionItemStore.setDone(true, itemID: item.id)
            settling[item.id] = nil
        }
    }

    private func trailingControls(_ item: ActionItem) -> some View {
        HStack(spacing: 10) {
            SecondaryPillButton("Take action") {
                open(item)
            }
            .revealOnHover(
                hoveredItemID == item.id && expandedItemID != item.id,
                reduceMotion: reduceMotion,
                anchor: .trailing,
                scale: 0.96
            )
            Image("nc-chevron-right")
                .icon(9)
                .foregroundStyle(hoveredItemID == item.id ? Theme.Palette.ink : Theme.Palette.muted)
                .rotationEffect(.degrees(expandedItemID == item.id ? 90 : 0))
        }
        .animation(.standard(reduceMotion: reduceMotion), value: hoveredItemID)
        .animation(.standard(reduceMotion: reduceMotion), value: expandedItemID)
    }

    @ViewBuilder
    private func meta(for item: ActionItem, showsSource: Bool) -> some View {
        let meeting = showsSource ? meetingStore.byID[item.meetingID] : nil
        if item.deadline != nil || meeting != nil || item.filed != nil {
            HStack(spacing: 6) {
                if let deadline = item.deadline {
                    Text(deadline)
                }
                // The source is a reference, not an action: a plain tappable
                // line, so opening evidence never competes with acting on the
                // item.
                if let meeting {
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
    }

    @ViewBuilder
    private func menu(for item: ActionItem) -> some View {
        Button(item.done || settling[item.id] != nil ? "Reopen" : "Mark done") {
            toggleDone(item)
        }
        if !intents.isEmpty {
            Divider()
            ForEach(intents) { offered in
                Button(offered.contextTitle(for: item)) {
                    withAnimation(.standard(reduceMotion: reduceMotion)) {
                        preselected = Preselection(itemID: item.id, intent: offered)
                        hoveredItemID = nil
                        expandedItemID = item.id
                    }
                }
            }
        }
        Divider()
        Button("Ask Nod about this") {
            onAsk(ActionDelegation.askPrompt(for: item, source: source(of: item)))
        }
        if let meeting = meetingStore.byID[item.meetingID] {
            Button("Open the source session") { onOpenMeeting(meeting) }
        }
    }

    private func sourceTitle(of item: ActionItem) -> String? {
        source(of: item)?.title
    }

    private func source(of item: ActionItem) -> KnowledgeChatStore.SessionRef? {
        guard let meeting = meetingStore.byID[item.meetingID] else { return nil }
        return KnowledgeChatStore.SessionRef(id: meeting.id, title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter))
    }

    private func toggle(_ item: ActionItem) {
        if expandedItemID == item.id {
            collapse()
        } else {
            open(item)
        }
    }

    private func open(_ item: ActionItem) {
        preselected = nil
        hoveredItemID = nil
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            expandedItemID = item.id
        }
    }

    private func collapse() {
        preselected = nil
        hoveredItemID = nil
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            expandedItemID = nil
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
