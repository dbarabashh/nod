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

    /// (done, total) while a backfill re-index is running; nil when idle.
    @State private var reindexProgress: ReindexProgress? = nil
    @State private var searchQuery: String = ""
    @State private var segment: Segment = .all
    @State private var pendingHardDelete: Meeting? = nil
    /// Identity of the currently-displayed undo toast — flipped each time
    /// `meetingStore.pendingUndo` changes, so the auto-dismiss timer
    /// belonging to the previous toast knows to skip its own dismissal.
    @State private var undoToastID: UUID = .init()
    @State private var path: [Meeting] = []

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
            if let id = initialFocusMeetingID {
                focus(on: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenMeetingDetail)) { note in
            if let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID {
                focus(on: id)
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

    private var navigationColumn: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    segmentBar
                    content
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
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .searchable(text: $searchQuery, prompt: "Search library")
            // Registered at the NavigationStack root so programmatic
            // pushes (via `path = [meeting]`) resolve even when the empty
            // / loading state is on screen instead of the list.
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(meeting: meeting)
            }
        }
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
                Text(dockSubtitle(meeting))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    /// Navigate the left column to a session (from a mention/source click in
    /// the cross-session chat). The dock then follows to that session's chat.
    private func openMeeting(_ id: UUID) {
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else { return }
        segment = .all
        path = [meeting]
    }

    private func dockSubtitle(_ meeting: Meeting?) -> String {
        if let meeting {
            return meeting.displayTitle(dateFormatter: Self.dockDateFormatter)
        }
        let n = meetingStore.meetings.count
        return n == 1 ? "1 session" : "\(n) sessions"
    }

    private static let dockDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Toolbar

    /// All / Trash filter. Lives at the top of the list pane, not the window
    /// toolbar — a `.principal` toolbar item centers across the *whole* window
    /// width, which floated it over the chat dock instead of the list it
    /// filters. Here it sits above the rows it controls.
    private var segmentBar: some View {
        Picker("View", selection: $segment) {
            ForEach(Segment.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onChange(of: segment) { new in
            if new == .trash, case .idle = meetingStore.trashState {
                Task { await meetingStore.refreshTrash() }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
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
                }
                .disabled(currentLoadState == .loading)
            }
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
            }
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
        let q = normalizedQuery
        if q.isEmpty { return rows }
        return rows.filter { meeting in
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
            NavigationLink(value: meeting) {
                MeetingRow(meeting: meeting, mode: .all)
            }
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
            MeetingRow(meeting: meeting, mode: .trash)
                .contextMenu {
                    Button {
                        Task { try? await meetingStore.restore(meeting.id) }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
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

// MARK: - Row

private struct MeetingRow: View {
    enum Mode { case all, trash }

    let meeting: Meeting
    let mode: Mode

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

                Text(meeting.summaryPreview)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 6)
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

/// Native macOS window vibrancy, replacing the flat pure-black fill. Under the
/// window's `.darkAqua` appearance this is a deep, slightly translucent surface
/// that picks up a hint of what's behind the window — the same frosted-glass
/// family as the floating panel, so the two halves of the app read as one
/// product instead of a flat slab bolted onto a glass panel.
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Helpers

private extension String {
    /// `nonEmpty` returns the string only if it's not empty — useful for
    /// `?? fallback` chains where empty should fall through.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
