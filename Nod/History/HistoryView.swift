import SwiftUI

/// List of past meetings, newest first. Two segments: All (live meetings)
/// and Trash (soft-deleted, 30-day retention before pg_cron purges them).
/// State-machine UI per segment: spinner / empty / list / error-with-retry.
/// Right-click context menu on rows for Delete / Restore / Delete Forever.
/// Soft-delete surfaces a 5-second Undo toast.
///
/// Issues #14 + #16.
struct HistoryView: View {
    /// Meeting to push onto the navigation stack on first mount. Set when
    /// AppDelegate opens the window in response to a just-ended meeting —
    /// the user lands directly on the detail view and can step back to
    /// the list. Nil when the window is opened from the menu bar.
    let initialFocusMeetingID: UUID?

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var chatStore: ChatStore

    /// (done, total) while a backfill re-index is running; nil when idle.
    @State private var reindexProgress: ReindexProgress? = nil
    @State private var searchQuery: String = ""
    @State private var segment: Segment = .all
    /// Active label filter on the All segment; nil shows every meeting.
    @State private var filterLabelID: UUID?
    @State private var pendingHardDelete: Meeting? = nil
    /// Identity of the currently-displayed undo toast — flipped each time
    /// `meetingStore.pendingUndo` changes, so the auto-dismiss timer
    /// belonging to the previous toast knows to skip its own dismissal.
    @State private var undoToastID: UUID = .init()
    @State private var path: [Meeting] = []
    @State private var confirmingClearChat = false

    init(initialFocusMeetingID: UUID? = nil) {
        self.initialFocusMeetingID = initialFocusMeetingID
    }

    enum Segment: String, CaseIterable, Identifiable {
        case all = "All"
        case trash = "Trash"
        var id: String {
            rawValue
        }
    }

    struct ReindexProgress: Equatable {
        let done: Int
        let total: Int
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationColumn
                .frame(maxWidth: .infinity)
            Divider().overlay(Theme.Palette.border)
            chatDock
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .task {
            // Always refresh on appear. The previous `.idle` gate would
            // skip refresh whenever the store already had data — including
            // the case where MeetingStore.insert() optimistically promoted
            // loadState to .loaded after a single new meeting, leaving the
            // list looking like a one-row history. MeetingStore.refresh()
            // dedupes concurrent calls and stays silent when there's
            // already a loaded cache, so calling on every appear is cheap.
            await meetingStore.refresh()
            await labelStore.refresh()
            if let id = initialFocusMeetingID {
                focus(on: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenMeetingDetail)) { note in
            if let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID {
                focus(on: id)
            }
        }
        .onChange(of: labelStore.labels) { labels in
            if let id = filterLabelID, !labels.contains(where: { $0.id == id }) {
                filterLabelID = nil
            }
        }
        .onChange(of: meetingStore.pendingUndo?.id) { newID in
            // A fresh soft-delete just landed — start the 5s auto-dismiss
            // window. Stamp a new local id so any in-flight prior timer
            // skips its own clear (rapid successive deletes shouldn't
            // clobber the latest toast).
            guard newID != nil else { return }
            let myID = UUID()
            undoToastID = myID
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    guard undoToastID == myID else { return }
                    if meetingStore.pendingUndo?.id == newID {
                        meetingStore.dismissUndo()
                    }
                }
            }
        }
        .alert("Delete forever?", isPresented: hardDeleteAlertVisible, presenting: pendingHardDelete) { meeting in
            Button("Delete Forever", role: .destructive) {
                Task { try? await meetingStore.hardDelete(meeting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { meeting in
            let label = meeting.title?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? "this meeting"
            Text("This permanently deletes \(label). This action can't be undone.")
        }
    }

    // MARK: - Navigation column (list + detail)

    /// Master/detail as a cross-fade, not a `NavigationStack` push — macOS can't
    /// give a stack a fade transition. `path.last` stays the source of truth.
    private var navigationColumn: some View {
        ZStack(alignment: .bottom) {
            if let meeting = path.last {
                MeetingDetailView(meeting: meeting, onClose: closeDetail)
                    .id(meeting.id)
                    .transition(.opacity)
            } else {
                libraryList
                    .transition(.opacity)
            }
            if let pending = meetingStore.pendingUndo {
                UndoToast(
                    message: "Moved to Trash",
                    onUndo: { Task { try? await meetingStore.restore(pending.id) } },
                    onDismiss: { meetingStore.dismissUndo() }
                )
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: path.last?.id)
    }

    /// In a `NavigationStack` only so the title, toolbar, and search field
    /// render — they need a navigation container. No destinations.
    private var libraryList: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentBar
                labelFilterBar
                content
                    .id(contentKey)
                    .transition(.opacity)
            }
            .navigationTitle("Library")
            .searchable(text: $searchQuery, prompt: "Search library")
        }
    }

    private func closeDetail() {
        path.removeAll()
    }

    // MARK: - Chat dock (right side)

    //
    // One persistent panel. Its scope follows the navigation: the open
    // session when you've drilled into one, otherwise every session at once.
    // Same composer, same look — no second window.

    private var chatDock: some View {
        VStack(spacing: 0) {
            dockHeader(for: path.last)
            Divider().overlay(Theme.Palette.border)
            Group {
                if let meeting = path.last {
                    // `.id` so switching sessions re-loads the thread + transcript.
                    SessionChatView(meeting: meeting).id(meeting.id)
                } else {
                    KnowledgeChatView(onOpenMeeting: openMeeting)
                }
            }
        }
        .frame(width: 380)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(width: 0.5)
        }
        .onChange(of: path.last?.id) { _ in confirmingClearChat = false }
    }

    private func dockHeader(for meeting: Meeting?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: meeting?.kind.icon ?? "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.violet)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting == nil ? "Ask across all sessions" : "Chat with this session")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if let subtitle = dockSubtitle(meeting) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let meeting, chatStore.loadState == .loaded, !chatStore.messages.isEmpty {
                clearChatControl(meetingID: meeting.id)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private func clearChatControl(meetingID: UUID) -> some View {
        if confirmingClearChat {
            HStack(spacing: 6) {
                Text("Clear history?")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.danger)
                InlineConfirmButtons(
                    confirmIcon: "eraser.fill",
                    confirmHelp: "Clear history",
                    cancelHelp: "Keep history",
                    onConfirm: {
                        confirmingClearChat = false
                        Task { await chatStore.clearHistory(meetingID: meetingID) }
                    },
                    onCancel: { confirmingClearChat = false }
                )
            }
        } else {
            Button { confirmingClearChat = true } label: {
                Image(systemName: "eraser")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Clear chat history")
        }
    }

    /// Navigate the left column to a session (from a mention/source click in
    /// the cross-session chat). The dock then follows to that session's chat.
    private func openMeeting(_ id: UUID) {
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else { return }
        segment = .all
        path = [meeting]
    }

    private func dockSubtitle(_ meeting: Meeting?) -> String? {
        guard let meeting else { return nil }
        return meeting.displayTitle(dateFormatter: Self.dockDateFormatter)
    }

    private static let dockDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Toolbar

    /// All / Trash filter plus the list-level actions (re-index, refresh).
    /// All of it lives at the top of the list pane, not the window toolbar —
    /// a window-toolbar item spans the *whole* window width, which floated
    /// these over the chat dock and crammed the action icons against the
    /// dock divider. Here they sit within the list column they control.
    private var segmentBar: some View {
        HStack(spacing: 8) {
            SegmentedControl(selection: $segment, animation: Self.contentFade)
                .frame(width: 200)
            Spacer(minLength: 12)
            listActions
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onChange(of: segment) { new in
            if new == .trash, case .idle = meetingStore.trashState {
                Task { await meetingStore.refreshTrash() }
            }
        }
    }

    /// Browse the library by label. Only on the All segment, and only once the
    /// user has at least one label.
    @ViewBuilder
    private var labelFilterBar: some View {
        if segment == .all, !labelStore.labels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    LabelFilterChip(title: "All", color: Theme.Palette.muted, isSelected: filterLabelID == nil) {
                        withAnimation(Self.contentFade) { filterLabelID = nil }
                    }
                    ForEach(labelStore.labels) { label in
                        LabelFilterChip(
                            title: label.name,
                            color: label.swatchColor,
                            isSelected: filterLabelID == label.id
                        ) {
                            withAnimation(Self.contentFade) {
                                filterLabelID = filterLabelID == label.id ? nil : label.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }

    private var listActions: some View {
        HStack(spacing: 6) {
            if meetingStore.lastRefreshFailed, segment == .all {
                // Non-blocking warning when a silent refresh failed
                // and we kept showing the cached list. Click to
                // retry. Without this the user sees a list that
                // looks current but may be stale by hours/days.
                Button(action: refreshActive) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Couldn't sync")
                            .font(.system(size: 11, weight: .regular))
                    }
                    .foregroundStyle(Theme.Palette.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Palette.warning.opacity(0.12))
                            .overlay(Capsule().stroke(Theme.Palette.warning.opacity(0.35), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .help("Showing cached meetings. Click to retry refresh.")
            }
            if segment == .all {
                reindexControl
            }
            Button(action: refreshActive) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(currentLoadState == .loading)
            .help("Refresh")
        }
    }

    @ViewBuilder
    private var reindexControl: some View {
        if let progress = reindexProgress {
            HStack(spacing: 5) {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text("Indexing \(progress.done)/\(progress.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
        } else if !meetingStore.meetings.isEmpty {
            Button(action: rebuildIndex) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Rebuild the search index so older sessions are findable in Ask Nod")
        }
    }

    /// Backfill: re-index every loaded session so ones recorded before
    /// indexing existed (or under older chunking) become searchable.
    private func rebuildIndex() {
        guard reindexProgress == nil else { return }
        let meetings = meetingStore.meetings
        guard !meetings.isEmpty else { return }
        reindexProgress = ReindexProgress(done: 0, total: meetings.count)
        Task {
            await knowledgeStore.reindex(
                meetings,
                transcript: { id in
                    let records = try await meetingStore.fetchTranscript(meetingID: id)
                    return records.map { record in
                        let label = TranscriptSource(rawValue: record.source)?.label ?? record.source
                        return "[\(label)] \(record.text)"
                    }.joined(separator: "\n")
                },
                progress: { done, total in
                    reindexProgress = ReindexProgress(done: done, total: total)
                }
            )
            reindexProgress = nil
        }
    }

    private func refreshActive() {
        Task {
            switch segment {
            case .all: await meetingStore.refresh(force: true)
            case .trash: await meetingStore.refreshTrash()
            }
        }
    }

    // MARK: - Content router

    /// Content-fade identity: tab + label, but not search — live-typing should
    /// filter in place, not re-fade on every keystroke.
    private var contentKey: String {
        "\(segment.rawValue)|\(filterLabelID?.uuidString ?? "")"
    }

    /// Driven via `withAnimation` at the mutation site: `.animation(value:)` on
    /// the `.id`-keyed content is torn down with that identity and never fires.
    private static let contentFade = Animation.easeInOut(duration: 0.2)

    @ViewBuilder
    private var content: some View {
        switch (segment, currentLoadState) {
        case (_, .idle), (_, .loading):
            loadingState
        case let (_, .failed(message)):
            errorState(message: message)
        case (.all, .loaded):
            allContent
        case (.trash, .loaded):
            trashContent
        }
    }

    @ViewBuilder
    private var allContent: some View {
        let rows = filtered(meetingStore.meetings)
        if meetingStore.meetings.isEmpty {
            emptyAllState
        } else if rows.isEmpty {
            noMatchesState
        } else {
            allList(rows)
        }
    }

    @ViewBuilder
    private var trashContent: some View {
        let rows = filtered(meetingStore.trashedMeetings)
        if meetingStore.trashedMeetings.isEmpty {
            emptyTrashState
        } else if rows.isEmpty {
            noMatchesState
        } else {
            trashList(rows)
        }
    }

    private var currentLoadState: MeetingStore.LoadState {
        segment == .all ? meetingStore.loadState : meetingStore.trashState
    }

    // MARK: - Filter

    private var normalizedQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func filtered(_ rows: [Meeting]) -> [Meeting] {
        var result = rows
        if segment == .all, let filterLabelID {
            let ids = labelStore.meetingIDs(withLabel: filterLabelID)
            result = result.filter { ids.contains($0.id) }
        }
        let q = normalizedQuery
        if q.isEmpty { return result }
        return result.filter { meeting in
            if let title = meeting.title?.lowercased(), title.contains(q) { return true }
            return meeting.summary.lowercased().contains(q)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.Palette.ink)
            Text("Loading…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyAllState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("No meetings yet.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Hit record on the floating panel to start your first.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var emptyTrashState: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("Trash is empty.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Items you delete appear here. They're permanently removed after 30 days.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("No matches for \u{201C}\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.warning)
            Text("Couldn't load.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: refreshActive) {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Lists

    private func allList(_ rows: [Meeting]) -> some View {
        List(rows) { meeting in
            MeetingRow(meeting: meeting, mode: .all)
                .onTapGesture { path.append(meeting) }
                .accessibilityAddTraits(.isButton)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.Palette.border)
                .contextMenu {
                    Button {
                        Task { await performSoftDelete(meeting) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        pendingHardDelete = meeting
                    } label: {
                        Label("Delete Forever", systemImage: "trash.fill")
                    }
                }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func trashList(_ rows: [Meeting]) -> some View {
        List(rows) { meeting in
            MeetingRow(meeting: meeting, mode: .trash) {
                Task { try? await meetingStore.restore(meeting.id) }
            }
            .contextMenu {
                Button(role: .destructive) {
                    pendingHardDelete = meeting
                } label: {
                    Label("Delete Forever", systemImage: "trash.fill")
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Palette.border)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Programmatic navigation

    /// Push the matching meeting (from the in-memory cache) onto the
    /// navigation stack so the user lands on its detail view. No-op if
    /// the id isn't in the cache — caller is responsible for inserting
    /// the meeting into MeetingStore before posting the focus signal.
    /// Flips the segment to `.all` so a user sitting on Trash when their
    /// just-ended meeting fires still sees the detail view.
    private func focus(on id: UUID) {
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else {
            Log.ui.info("HistoryView.focus skipped — meeting not in cache: \(id.uuidString)")
            return
        }
        segment = .all
        path = [meeting]
    }

    // MARK: - Soft delete (Undo toast is driven by meetingStore.pendingUndo)

    private func performSoftDelete(_ meeting: Meeting) async {
        do {
            try await meetingStore.softDelete(meeting)
        } catch {
            Log.ui.error("softDelete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hard-delete alert binding

    private var hardDeleteAlertVisible: Binding<Bool> {
        Binding(
            get: { pendingHardDelete != nil },
            set: { if !$0 { pendingHardDelete = nil } }
        )
    }
}

// MARK: - Segmented control

/// Design-system segmented control — replaces `.pickerStyle(.segmented)`, whose
/// selection paints with the macOS system accent (blue) that's off-palette here.
/// Selected segment is a raised `surfaceStrong` pill (sliding via matched
/// geometry) with `ink` text; unselected is `muted`.
private struct SegmentedControl: View {
    @Binding var selection: HistoryView.Segment
    let animation: Animation
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HistoryView.Segment.allCases) { segment in
                let isSelected = selection == segment
                Text(segment.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.Palette.surfaceStrong)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard selection != segment else { return }
                        withAnimation(animation) { selection = segment }
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Row

private struct MeetingRow: View {
    enum Mode { case all, trash }

    let meeting: Meeting
    let mode: Mode
    var onRestore: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            kindIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.displayTitle(dateFormatter: Self.dateFormatter))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Metadata keeps its slot (only fades) and Restore overlays
                    // it, so the row never changes height on hover.
                    trailingMeta
                        .opacity(showRestore ? 0 : 1)
                        .overlay(alignment: .trailing) {
                            restoreButton
                                .revealOnHover(showRestore, reduceMotion: reduceMotion, anchor: .trailing)
                        }
                        .padding(.trailing, 8)
                }

                Text(meeting.summaryPreview)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .opacity(isHovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.hoverReveal(reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
    }

    private var showRestore: Bool {
        mode == .trash && isHovering
    }

    /// Trailing badges, grouped so they fade as a unit under the Restore overlay.
    private var trailingMeta: some View {
        HStack(spacing: 8) {
            if mode == .trash, let trashedAt = meeting.deletedAt {
                Text(Self.relativeTrashedLabel(for: trashedAt))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(meeting.language.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(Theme.Palette.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.surface)
                )
        }
    }

    /// Hover affordance in Trash; overlays the metadata slot so layout never shifts.
    private var restoreButton: some View {
        Button {
            onRestore?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                Text("Restore")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Restore to All")
        .linkCursor()
    }

    /// Leading type marker — color-coded so meeting / voice note / media are
    /// scannable at a glance. Tooltip spells out the kind for the unsure.
    private var kindIcon: some View {
        Image(systemName: meeting.kind.icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kindTint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(kindTint.opacity(0.14))
            )
            .help(meeting.kind.title)
    }

    private var kindTint: Color {
        switch meeting.kind {
        case .meeting: Theme.Palette.violet
        case .voiceNote: Theme.Palette.cyan
        case .media: Theme.Palette.warning
        }
    }

    /// "deleted 2d ago" — gives the user a sense of the 30-day countdown
    /// before pg_cron sweeps the row.
    private static func relativeTrashedLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "trashed " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Undo toast

private struct UndoToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.Palette.bgSoft.opacity(0.85)))
                .overlay(Capsule().stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

// MARK: - Window backdrop

// MARK: - Helpers

private extension String {
    /// `nonEmpty` returns the string only if it's not empty — useful for
    /// `?? fallback` chains where empty should fall through.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
