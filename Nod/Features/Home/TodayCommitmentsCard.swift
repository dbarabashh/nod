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
    @State private var completionCandidates: [ActionItem] = []
    @State private var confirmsCompletion = false
    /// The full list by the session that produced each item, rebuilt when the
    /// items or the sessions change rather than on every body pass: with a
    /// hundred open commitments the grouping and its date formatting were
    /// running on each hover.
    @State private var groups: [ActionGroup] = []
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
    struct Preselection: Equatable {
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

    private var intents: [ActionIntent] {
        ActionIntent.available(usable: integrations.isUsable)
    }

    /// What the grouping is a function of, as one value: `onChange` hands the
    /// new value to its closure, and the closure must use that rather than
    /// read `openItems` off `self` — the closure SwiftUI runs can belong to
    /// the previous body, whose `self` still holds the list before the tick.
    private struct GroupingInput: Equatable {
        let items: [ActionItem]
        let digest: MeetingStore.DigestKey
    }

    private var groupingInput: GroupingInput {
        GroupingInput(items: openItems, digest: meetingStore.digestKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            if showAll {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        groupCard(group)
                            .zIndex(group.items.contains { $0.id == expandedItemID } ? 1 : 0)
                    }
                }
            } else {
                TodayCardList(title: "Waiting on you", items: shown, showsTitle: false) { item in
                    row(item, showsSource: true)
                        // The drawer's pickers float out of their row; without
                        // this the rows below, drawn later, paint over them.
                        .zIndex(expandedItemID == item.id ? 1 : 0)
                }
            }
            if actionItemStore.completionFailureCount > 0 {
                Text("Couldn't complete \(actionItemStore.completionFailureCount) tasks. They remain open; try again.")
                    .textStyle(Theme.Typography.meta)
                    .foregroundStyle(Theme.Palette.danger)
            }
            if showAll || hiddenCount > 0 {
                revealButton
            }
        }
        .onChange(of: groupingInput) { input in regroup(input.items) }
        .alert("Mark all \(completionCandidates.count) tasks as done?", isPresented: $confirmsCompletion) {
            Button("Cancel", role: .cancel) { completionCandidates = [] }
            Button("Mark all done") {
                let confirmed = completionCandidates
                completionCandidates = []
                settling.values.forEach { $0.cancel() }
                settling = [:]
                collapse()
                Task { await actionItemStore.completeAll(confirmed) }
            }
        } message: {
            Text(completionMessage)
        }
    }

    private var sectionHeader: some View {
        HStack {
            SectionLabel("Waiting on you")
            Spacer()
            Button(actionItemStore.isCompletingAll ? "Marking done…" : "Mark all done") {
                completionCandidates = openItems.filter { $0.isOpen && actionItemStore.isMine($0) }
                confirmsCompletion = !completionCandidates.isEmpty
            }
            .buttonStyle(.plain)
            .textStyle(Theme.Typography.meta)
            .foregroundStyle(Theme.Palette.muted)
            .disabled(actionItemStore.isCompletingAll || openItems.isEmpty)
        }
    }

    private var completionMessage: String {
        let base = "All tasks in Waiting on you will be marked done, including those in collapsed groups and under See more. Tasks added after this confirmation opens are not included."
        if completionCandidates.contains(where: { $0.filed != nil }) {
            return base + " Linked tasks will also be updated through their existing connections."
        }
        return base
    }

    private var revealButton: some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) {
                showAll.toggle()
                collapsedGroupIDs = []
                regroup(openItems)
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

    private func regroup(_ items: [ActionItem]) {
        guard showAll else {
            groups = []
            return
        }
        groups = ActionGrouping.bySession(items, meetings: meetingStore.byID)
    }

    private func groupCard(_ group: ActionGroup) -> some View {
        LazyVStack(spacing: 0) {
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
        CommitmentRow(
            item: item,
            showsSource: showsSource,
            isExpanded: expandedItemID == item.id,
            isSettling: settling[item.id] != nil,
            ambientHints: ambientHints[item.id] ?? [],
            preselection: preselected?.itemID == item.id ? preselected : nil,
            intents: intents,
            onToggleDone: { toggleDone(item) },
            onToggle: { toggle(item) },
            onOpen: { open(item) },
            onPreselect: { preselect($0, for: item) },
            onClose: collapse,
            onAsk: onAsk,
            onOpenMeeting: onOpenMeeting
        )
        .disabled(actionItemStore.isCompletingAll)
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

    private func preselect(_ intent: ActionIntent, for item: ActionItem) {
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            preselected = Preselection(itemID: item.id, intent: intent)
            expandedItemID = item.id
        }
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
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            expandedItemID = item.id
        }
    }

    private func collapse() {
        preselected = nil
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            expandedItemID = nil
        }
    }
}

/// One commitment. Owns its own hover so the pointer crossing a row redraws
/// that row alone: hover kept on the card re-evaluated every row it held, and
/// a hundred of them under a moving cursor is what a frozen scroll was.
private struct CommitmentRow: View {
    let item: ActionItem
    let showsSource: Bool
    let isExpanded: Bool
    let isSettling: Bool
    let ambientHints: [ScreenObservation]
    let preselection: TodayCommitmentsCard.Preselection?
    let intents: [ActionIntent]
    let onToggleDone: () -> Void
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onPreselect: (ActionIntent) -> Void
    let onClose: () -> Void
    let onAsk: (ActionDelegation.AskRequest) -> Void
    let onOpenMeeting: (Meeting) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var showsHover: Bool {
        isHovered && !isExpanded
    }

    private var isTicked: Bool {
        item.done || isSettling
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                ActionItemDrawer(
                    item: item,
                    sourceTitle: meetingStore.byID[item.meetingID]?
                        .displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    ambientHints: ambientHints,
                    preselectedIntent: preselection?.intent,
                    onAsk: onAsk,
                    onOpenSource: {
                        if let meeting = meetingStore.byID[item.meetingID] { onOpenMeeting(meeting) }
                    },
                    onClose: onClose
                )
                // A fresh token is a fresh identity, which is the only thing
                // that re-seeds the drawer's intent — picking an outcome from
                // the context menu of a row that is already open, or picking
                // the same one twice, would otherwise change nothing.
                .id(preselection?.token)
                .padding(.leading, 44)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button(action: onToggleDone) {
                    ActionCheckbox(done: isTicked)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help(isTicked ? "Reopen" : "Mark done")

                // The click opens the actions, in place. The session is
                // evidence — reachable as the header's arrow, or the drawer's
                // quote — not where a task's click should land.
                Button(action: onToggle) {
                    summary
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
            trailingControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // Inset well clear of the card's own 18pt corner, and a step lighter
        // than the default: the rows already sit on a `surfaceCard` fill, and
        // the two together read as a slab rather than a pointer.
        .hoverHighlight(
            showsHover,
            cornerRadius: 10,
            reduceMotion: reduceMotion,
            inset: CGSize(width: 6, height: 3),
            fill: Theme.Palette.surface
        )
        .onHover { isHovered = $0 }
        .contextMenu { menu }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.ink)
                .strikethrough(isSettling, color: Theme.Palette.muted)
                .opacity(isSettling ? 0.55 : 1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            meta
            if let hint = ambientHints.first {
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

    private var trailingControls: some View {
        HStack(spacing: 10) {
            SecondaryPillButton("Take action", action: onOpen)
                .revealOnHover(
                    showsHover,
                    reduceMotion: reduceMotion,
                    anchor: .trailing,
                    scale: 0.96
                )
            Image("nc-chevron-right")
                .icon(9)
                .foregroundStyle(showsHover ? Theme.Palette.ink : Theme.Palette.muted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .animation(.standard(reduceMotion: reduceMotion), value: showsHover)
        .animation(.standard(reduceMotion: reduceMotion), value: isExpanded)
    }

    @ViewBuilder
    private var meta: some View {
        let meeting = showsSource ? meetingStore.byID[item.meetingID] : nil
        if item.deadline != nil || meeting != nil || item.filed != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let deadline = item.deadline {
                    Text(deadline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.Palette.muted)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(isTicked ? "Reopen" : "Mark done", action: onToggleDone)
        if !intents.isEmpty {
            Divider()
            ForEach(intents) { offered in
                Button(offered.contextTitle(for: item)) {
                    onPreselect(offered)
                }
            }
        }
        Divider()
        Button("Ask Nod about this") {
            onAsk(ActionDelegation.askPrompt(for: item, source: source))
        }
        if let meeting = meetingStore.byID[item.meetingID] {
            Button("Open the source session") { onOpenMeeting(meeting) }
        }
    }

    private var source: KnowledgeChatStore.SessionRef? {
        guard let meeting = meetingStore.byID[item.meetingID] else { return nil }
        return KnowledgeChatStore.SessionRef(id: meeting.id, title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter))
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
