import SwiftUI

/// The right column when no session is open: what still needs the user, always
/// on screen rather than behind a tab. Three blocks — open actions, threads the
/// meetings left open, and the recent sessions themselves — each row pointing
/// back at the conversation it came from.
///
/// Everything here is derived from data already loaded (`TodayDigest`); the
/// column never asks the model anything.
struct AttentionColumn: View {
    let onOpenMeeting: (UUID) -> Void
    /// Open one task as its own surface — what it is, when it's due, and where
    /// it came from. A task the user can't trace is a task they won't trust.
    let onOpenAction: (TodayDigest.OpenAction) -> Void
    /// Open the full cross-session checklist from the block header.
    let onOpenActionItems: () -> Void
    let onOpenSessions: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ranked top few, re-derived when the store or the session set
    /// changes. Ticking a box rewrites the row in place instead of re-deriving,
    /// so a task doesn't vanish from under the pointer mid-click.
    @State private var actions: [TodayDigest.OpenAction] = []
    @State private var points: [TodayDigest.OpenPoint] = []
    @State private var recentSessions: [Meeting] = []
    /// Totals, not the length of the truncated lists below — the brief on the
    /// home screen counts the same way, and a header that said 8 while the card
    /// said 12 would make both numbers worthless.
    @State private var openActionCount = 0
    @State private var unresolvedCount = 0
    @State private var loaded = false
    @State private var hoveredRow: String?
    @State private var filter: Filter = .all

    /// The column is a list of things to do something about, so it filters by
    /// what kind of thing — otherwise it reads as one undifferentiated feed
    /// that only ever grows.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case actions = "Actions"
        case unresolved = "Unresolved"
        case sessions = "Sessions"
        var id: String {
            rawValue
        }
    }

    private var canUseActionItems: Bool {
        entitlements.mayUse(.actionItems)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .tooltipContainer()
        // The store holds the rows; this only re-derives what it shows — the
        // ranked top five, the counts, and the session-derived blocks.
        .task { await actionItemStore.refresh() }
        .onChange(of: actionItemStore.revision) { _ in deriveActions() }
        .onChange(of: meetingStore.meetings) { _ in derive() }
        .onAppear(perform: derive)
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            if loaded { emptyState } else { loadingState }
        } else {
            if shows(.actions) {
                if canUseActionItems {
                    openActionsBlock
                } else {
                    actionsUpsellBlock
                }
            }
            if shows(.unresolved), !points.isEmpty { unresolvedBlock }
            if shows(.sessions), !recentSessions.isEmpty { recentBlock }
        }
    }

    private var isEmpty: Bool {
        actions.isEmpty && points.isEmpty && recentSessions.isEmpty
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Needs your attention")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                countBadge(attentionCount)
                Spacer(minLength: 0)
            }
            filterBar
        }
        .padding(.horizontal, 4)
    }

    /// Open work only — recent sessions are context, not something to act on.
    private var attentionCount: Int {
        openActionCount + unresolvedCount
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases) { option in
                let selected = filter == option
                Button {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { filter = option }
                } label: {
                    HStack(spacing: 4) {
                        Text(option.rawValue)
                        if let count = count(for: option) {
                            Text("\(count)")
                                .opacity(0.65)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Theme.Palette.surfaceStrong : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.Palette.surface))
        }
    }

    private func count(for option: Filter) -> Int? {
        switch option {
        case .all: nil
        case .actions: openActionCount
        case .unresolved: unresolvedCount
        case .sessions: recentSessions.count
        }
    }

    private func shows(_ option: Filter) -> Bool {
        filter == .all || filter == option
    }

    private func blockHeader(_ title: String, count: Int, action: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            SectionLabel(title)
            countBadge(count)
            Spacer(minLength: 0)
            if let action { SeeAllButton(action: action) }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Open actions

    private var openActionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Open actions", count: openActionCount, action: onOpenActionItems)
            card {
                if actions.isEmpty {
                    // The block stays even when nothing is open: its header
                    // carries the only route into the full checklist.
                    Text(loaded ? "Nothing open." : "Loading…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                } else {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        actionRow(action)
                        if index < actions.count - 1 { rowDivider(leading: 34) }
                    }
                }
            }
        }
    }

    /// Two lines, never more: the task, then where it came from and when it's
    /// due on one quiet line. The full sentence lives in the item's own screen —
    /// a column where every row is a paragraph is a column nobody scans.
    private func actionRow(_ action: TodayDigest.OpenAction) -> some View {
        rowShell(id: action.id.uuidString, open: { onOpenAction(action) }) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                ActionCheckbox(done: action.item.done)
                    .onTapGesture { Task { await toggle(action) } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.item.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(action.item.done ? Theme.Palette.muted : Theme.Palette.ink)
                        .strikethrough(action.item.done, color: Theme.Palette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(title(of: action.meeting))
                            .lineLimit(1)
                        if let deadline = action.deadline {
                            Text("·")
                            Text(deadline.text)
                                .foregroundStyle(action.item.done ? Theme.Palette.muted : deadline.urgency.tint)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The checklist is Pro-only and has no rail item of its own, so without
    /// this a Starter user would never learn the feature exists — they'd just
    /// see the top block silently missing.
    private var actionsUpsellBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Open actions", count: 0, action: nil)
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nod pulls the to-dos out of every session into one checklist you can tick off.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                    } label: {
                        Text("Upgrade to Pro")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.GlassButton.text)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .glassButtonSurface(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Unresolved

    private var unresolvedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Unresolved", count: unresolvedCount, action: nil)
            card {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    pointRow(point)
                    if index < points.count - 1 { rowDivider(leading: 34) }
                }
            }
        }
    }

    private func pointRow(_ point: TodayDigest.OpenPoint) -> some View {
        rowShell(id: point.id, open: { onOpenMeeting(point.meeting.id) }) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image("nc-msgs")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.warning)
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(title(of: point.meeting))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Recent sessions

    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Recent sessions", count: 0, action: onOpenSessions)
            card {
                let sessions = recentSessions
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, meeting in
                    sessionRow(meeting)
                    if index < sessions.count - 1 { rowDivider(leading: 34) }
                }
            }
        }
    }

    private func sessionRow(_ meeting: Meeting) -> some View {
        rowShell(id: meeting.id.uuidString, open: { onOpenMeeting(meeting.id) }) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: meeting.kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.7))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: meeting))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Meeting.ago(meeting.startedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Shared chrome

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
    }

    private func rowDivider(leading: CGFloat) -> some View {
        Divider()
            .overlay(Theme.Palette.border.opacity(0.6))
            .padding(.leading, leading)
    }

    /// One row = one interactive lock-up: a single containing shape that
    /// highlights on hover, inset inside the card so neighbouring highlights
    /// never touch, with a radius concentric to the card's (12 − 4 inset = 8).
    private func rowShell(
        id: String,
        open: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(
                hoveredRow == id,
                reduceMotion: reduceMotion,
                inset: CGSize(width: 4, height: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { hovering in
                if hovering { hoveredRow = id } else if hoveredRow == id { hoveredRow = nil }
            }
            .help("Open this session")
    }

    private var loadingState: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("nc-check")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("Nothing needs you right now.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Record a meeting or a voice note and what came out of it shows up here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 24)
    }

    // MARK: - Data

    private func title(of meeting: Meeting) -> String {
        meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
    }

    private func derive() {
        deriveLocal()
        deriveActions()
    }

    private func deriveActions() {
        guard canUseActionItems else { loaded = true; return }
        actions = TodayDigest.openActions(
            items: actionItemStore.items,
            meetings: meetingStore.meetings,
            limit: 5
        )
        openActionCount = actionItemStore.openItems.count
        loaded = true
    }

    private func deriveLocal() {
        points = TodayDigest.openPoints(meetings: meetingStore.meetings, limit: 3)
        unresolvedCount = TodayDigest.openPointCount(meetings: meetingStore.meetings)
        recentSessions = TodayDigest.recentSessions(meetingStore.meetings, limit: 4)
    }

    /// The store owns the flip and its rollback. The row is only rewritten in
    /// place here so a ticked task doesn't vanish from under the pointer —
    /// re-deriving would drop it out of the open list mid-click.
    private func toggle(_ action: TodayDigest.OpenAction) async {
        await actionItemStore.setDone(!action.item.done, itemID: action.item.id)
        guard let index = actions.firstIndex(where: { $0.id == action.id }),
              let updated = actionItemStore.items.first(where: { $0.id == action.id }) else {
            openActionCount = actionItemStore.openItems.count
            return
        }
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            actions[index] = TodayDigest.OpenAction(
                item: updated,
                meeting: action.meeting,
                deadline: action.deadline
            )
        }
        openActionCount = actionItemStore.openItems.count
    }
}

/// "See all ›" beside a block header. A word plus the chevron, on its own
/// surface — this is the only route into the full list behind a block.
private struct SeeAllButton: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("See all")
                    .font(.system(size: 10.5, weight: .semibold))
                Image("nc-chevron-right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(isHovering ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .hoverSurface(isHovering, in: Capsule(style: .continuous), reduceMotion: reduceMotion)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .linkCursor()
        .help("See all")
    }
}
