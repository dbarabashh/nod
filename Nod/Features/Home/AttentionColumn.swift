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
    /// Open the full cross-session checklist from the block header.
    let onOpenActionItems: () -> Void
    let onOpenSessions: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Snapshot taken when the column loads. Ticking a box flips `done` in
    /// place rather than re-deriving the list, so the row stays put (and stays
    /// un-tickable) instead of vanishing under the pointer.
    @State private var actions: [TodayDigest.OpenAction] = []
    @State private var points: [TodayDigest.OpenPoint] = []
    @State private var recentSessions: [Meeting] = []
    @State private var inFlight: Set<UUID> = []
    @State private var loaded = false
    @State private var hoveredRow: String?

    /// Fail OPEN on an unresolved entitlement, like every other Pro gate: a Pro
    /// user whose entitlement fetch transiently failed still sees their tasks.
    private var canUseActionItems: Bool {
        entitlements.entitlement == nil || entitlements.can(.actionItems)
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
        // Two triggers, because they cost differently: the local derivations
        // re-run whenever any session changes (a recap landing after generation
        // rewrites the row in place, which the count-based key can't see), while
        // the network fetch only re-runs when the set itself changes.
        .task(id: meetingStore.digestKey) { await loadActions() }
        .onChange(of: meetingStore.meetings) { _ in deriveLocal() }
        .onAppear(perform: deriveLocal)
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            if loaded { emptyState } else { loadingState }
        } else {
            if canUseActionItems {
                openActionsBlock
            } else {
                actionsUpsellBlock
            }
            if !points.isEmpty { unresolvedBlock }
            if !recentSessions.isEmpty { recentBlock }
        }
    }

    private var isEmpty: Bool {
        actions.isEmpty && points.isEmpty && recentSessions.isEmpty
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Needs your attention")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            Text(Self.dayFormatter.string(from: Date()))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
        }
        .padding(.horizontal, 4)
    }

    private func blockHeader(_ title: String, count: Int, action: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Palette.surface))
            }
            Spacer(minLength: 0)
            if let action {
                Button(action: action) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 20, height: 16)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("See all")
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Open actions

    private var openActionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader("Open actions", count: actions.filter { !$0.item.done }.count, action: onOpenActionItems)
            card {
                if actions.isEmpty {
                    // The chevron beside the header is the only way into the full
                    // checklist, so the block stays even when nothing is open.
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

    private func actionRow(_ action: TodayDigest.OpenAction) -> some View {
        rowShell(id: action.id.uuidString, open: { onOpenMeeting(action.meeting.id) }) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                ActionCheckbox(done: action.item.done)
                    .onTapGesture { Task { await toggle(action) } }
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.item.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(action.item.done ? Theme.Palette.muted : Theme.Palette.ink)
                        .strikethrough(action.item.done, color: Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    sourceLabel(action.meeting)
                    if let deadline = action.deadline {
                        DeadlinePill(
                            display: deadline,
                            spokenAt: action.meeting.startedAt,
                            meetingTitle: title(of: action.meeting),
                            compact: true
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(inFlight.contains(action.item.id) ? 0.5 : 1)
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
            blockHeader("Unresolved", count: points.count, action: nil)
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
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.warning)
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 4) {
                    Text(point.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    sourceLabel(point.meeting)
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

    /// Where this line came from. Not a control of its own: the whole row opens
    /// the session, so the row reads as one target that highlights as a unit.
    private func sourceLabel(_ meeting: Meeting) -> some View {
        HStack(spacing: 4) {
            Image(systemName: meeting.kind.icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(title(of: meeting))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text("·")
                .font(.system(size: 11))
            Text(Meeting.ago(meeting.startedAt))
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.Palette.muted)
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
            Image(systemName: "checkmark.circle")
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

    private func deriveLocal() {
        points = TodayDigest.openPoints(meetings: meetingStore.meetings, limit: 3)
        recentSessions = TodayDigest.recentSessions(meetingStore.meetings, limit: 4)
    }

    private func loadActions() async {
        deriveLocal()
        if canUseActionItems {
            do {
                let items = try await actionItemStore.openItems(limit: 40)
                actions = TodayDigest.openActions(items: items, meetings: meetingStore.meetings, limit: 5)
            } catch {
                Log.ui.error("AttentionColumn.loadActions failed: \(error.localizedDescription)")
            }
        }
        loaded = true
    }

    private func toggle(_ action: TodayDigest.OpenAction) async {
        let id = action.item.id
        guard let index = actions.firstIndex(where: { $0.id == id }), !inFlight.contains(id) else { return }
        let previous = actions[index].item
        let target = !previous.done
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            actions[index] = TodayDigest.OpenAction(
                item: previous.marked(done: target, at: Date()),
                meeting: actions[index].meeting,
                deadline: actions[index].deadline
            )
        }
        do {
            try await actionItemStore.setDone(target, itemID: id)
        } catch {
            if let i = actions.firstIndex(where: { $0.id == id }) {
                actions[i] = TodayDigest.OpenAction(item: previous, meeting: actions[i].meeting, deadline: actions[i].deadline)
            }
            Log.ui.error("AttentionColumn.toggle failed: \(error.localizedDescription)")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()
}
