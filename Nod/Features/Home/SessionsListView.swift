import SwiftUI

/// The sessions browser: search, All/Trash, the project filter, and the list
/// itself. Its own view rather than another 400 lines inside the window shell —
/// the shell's job is choosing which surface to show, not being one.
struct SessionsListView: View {
    /// Live sessions or the trash. Passed in rather than held here: the two are
    /// separate sidebar destinations now, so which one is showing is the
    /// window's business, not a control inside the list.
    let mode: Segment
    /// Project filter, owned by the window: picking a project in the sidebar
    /// navigates here with it already applied.
    @Binding var filterLabelID: UUID?
    let onOpen: (Meeting) -> Void
    /// Same intent the sidebar's Capture button dispatches, minus the kind
    /// picker: the empty state offers one thing, and it's a meeting.
    let onStartCapture: () -> Void
    /// Scope Ask Nod to this project and go there — the one action that treats
    /// a project as memory rather than as a filter.
    let onAskAboutProject: (SessionLabel) -> Void
    let panelShortcut: String

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var labelStore: LabelStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    @State private var owner: Owner = .everyone
    @State private var reindexProgress: ReindexProgress?
    @State private var pendingHardDelete: Meeting?

    /// Which of the two lists this is. Not a control any more — the window
    /// picks it from the sidebar destination.
    enum Segment: String {
        case all
        case trash
    }

    /// Whose session this is — the question a colleague's shared recording
    /// raises the moment it lands in the list beside your own.
    ///
    /// A filter rather than a context to switch into, because that is what the
    /// data supports: what you can read is decided by membership and by the
    /// grants on each session, and no context you could be in changes it. A
    /// switcher would have implied a partition that does not exist.
    enum Owner: String, CaseIterable, Identifiable {
        case everyone = "All"
        case mine = "Mine"
        case shared = "Shared with me"
        /// Where a hidden session can be found again. Hiding has no other way
        /// back — the row is the whole of the state — so the list that shows
        /// them is the undo.
        case hidden = "Hidden"
        var id: String {
            rawValue
        }
    }

    struct ReindexProgress: Equatable {
        let done: Int
        let total: Int
    }

    var body: some View {
        sessionsList
            .alert("Delete forever?", isPresented: hardDeleteAlertVisible, presenting: pendingHardDelete) { meeting in
                Button("Delete Forever", role: .destructive) {
                    // `MeetingStore.hardDelete` itself refuses the actively-
                    // recording meeting's id — the context menu's `.disabled`
                    // below is only the UX nicety of not offering the option
                    // in the first place, not the enforcement.
                    Task { try? await meetingStore.hardDelete(meeting.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { meeting in
                let label = meeting.title?.trimmingCharacters(in: .whitespaces).nonEmpty
                    ?? "this meeting"
                Text("This permanently deletes \(label). This action can't be undone.")
            }
    }

    private var sessionsList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            projectSummary
            toolbar
            activeFilters
            content
                .id(contentKey)
                .transition(.opacity)
        }
        .onChange(of: labelStore.labels) { _ in clearFilterIfProjectVanished() }
        .onAppear(perform: clearFilterIfProjectVanished)
        // The segmented control used to load the trash the first time it was
        // selected. It is a destination now, so arriving is the trigger.
        .task(id: mode) {
            guard mode == .trash, case .idle = meetingStore.trashState else { return }
            await meetingStore.refreshTrash()
        }
    }

    private var title: String {
        guard mode == .all else { return "Trash" }
        return activeProject?.name ?? "Sessions"
    }

    private var activeProject: SessionLabel? {
        guard let filterLabelID else { return nil }
        return labelStore.labels.first { $0.id == filterLabelID }
    }

    /// A filter can outlive the folder it points at — somebody stops sharing a
    /// project while you are standing inside it. The list then matches nothing,
    /// the header falls back to "Sessions", and "Clear filter" disappears along
    /// with the project it belonged to, leaving no way out of an empty screen.
    /// Dropping the filter puts the person back where they can see their work.
    private func clearFilterIfProjectVanished() {
        guard let filterLabelID, !labelStore.labels.contains(where: { $0.id == filterLabelID }) else { return }
        self.filterLabelID = nil
    }

    /// A project is a scope over memory, not a folder of files — so opening one
    /// says what Nod knows about it before it lists what it was told. The button
    /// is the point: the useful thing to do with everything known about Capable
    /// is to ask about Capable.
    @ViewBuilder private var projectSummary: some View {
        if let project = activeProject {
            let sessions = projectSessions
            let counts = SessionKnowledge.across(sessions)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.projectLine(sessions: sessions.count, counts: counts))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 8)
                Button { onAskAboutProject(project) } label: {
                    HStack(spacing: 5) {
                        Image("nc-sparkle-3")
                            .icon(10)
                        Text("Ask about \(project.name)")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Palette.violet)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
        }
    }

    private var projectSessions: [Meeting] {
        guard let filterLabelID else { return [] }
        let ids = labelStore.meetingIDs(withLabel: filterLabelID)
        return meetingStore.meetings.live().filter { ids.contains($0.id) }
    }

    private static func projectLine(sessions: Int, counts: SessionKnowledge) -> String {
        var parts = ["\(sessions) \(sessions == 1 ? "session" : "sessions")"]
        if !counts.isEmpty { parts.append(counts.summary) }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        SearchField(prompt: "Search sessions", text: $searchQuery)
            .frame(maxWidth: 280)
    }

    /// The only permanent row of controls. What used to sit under it — a
    /// segmented control for the trash, another for whose sessions these are,
    /// and a chip per project — described three different things at the same
    /// altitude and cost the list a hundred points of height before a single
    /// row of content. The trash is a place now, the project comes from the
    /// sidebar, and ownership is a filter you open rather than one you scroll
    /// past.
    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField
            Spacer(minLength: 12)
            if mode == .all, meetingStore.hasSharedSessions {
                ownerFilterMenu
            }
            listActions
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Absent until somebody else's session is actually in the list. For an
    /// account working alone every row is theirs, and a filter whose two other
    /// options are both empty is a control that only asks a question.
    private var ownerFilterMenu: some View {
        Menu {
            Picker("Show", selection: $owner) {
                ForEach(Owner.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image("nc-filter")
                    .icon(12)
                Text(owner == .everyone ? "Filter" : owner.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(owner == .everyone ? Theme.Palette.muted : Theme.Palette.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by whose session it is")
    }

    /// What is narrowing the list right now, and the way out of it. Nothing is
    /// drawn while the list is unfiltered — which is most of the time, and the
    /// state the old three bars charged the most for.
    @ViewBuilder
    private var activeFilters: some View {
        let chips = appliedFilters
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    FilterChip(title: chip.title, color: chip.color, onRemove: chip.remove)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private struct AppliedFilter: Identifiable {
        let id: String
        let title: String
        let color: Color?
        let remove: () -> Void
    }

    private var appliedFilters: [AppliedFilter] {
        guard mode == .all else { return [] }
        var chips: [AppliedFilter] = []
        if let project = activeProject {
            chips.append(AppliedFilter(id: "project", title: project.name, color: project.swatchColor) {
                withAnimation(Self.contentFade) { filterLabelID = nil }
            })
        }
        if owner != .everyone {
            chips.append(AppliedFilter(id: "owner", title: owner.rawValue, color: nil) {
                withAnimation(Self.contentFade) { owner = .everyone }
            })
        }
        return chips
    }

    private var listActions: some View {
        HStack(spacing: 6) {
            if meetingStore.lastRefreshFailed, mode == .all {
                Button(action: refreshActive) {
                    HStack(spacing: 4) {
                        Image("nc-triangle-warning")
                            .icon(11)
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
                .help("Showing cached sessions. Click to retry refresh.")
            }
            if mode == .all {
                reindexControl
            }
            Button(action: refreshActive) {
                Image("nc-refresh-2")
                    .icon(13)
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
                Image("nc-sparkle-3")
                    .icon(13)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Rebuild the search index so older sessions are findable in Ask Nod")
        }
    }

    /// Backfill: re-index every loaded session so ones recorded before indexing
    /// existed (or under older chunking) become searchable.
    private func rebuildIndex() {
        guard reindexProgress == nil else { return }
        // Own sessions only. The index is per-account and the proxy refuses a
        // meeting the caller does not own, so a shared one costs a transcript
        // fetch and a rejected round trip to end up exactly where it started.
        let meetings = meetingStore.meetings.filter { !meetingStore.isSharedWithMe($0) }
        guard !meetings.isEmpty else { return }
        reindexProgress = ReindexProgress(done: 0, total: meetings.count)
        Task {
            await knowledgeStore.reindex(
                meetings,
                transcript: { id in
                    let records = try await meetingStore.fetchTranscript(meetingID: id)
                    return records.promptContext(names: meetingStore.byID[id]?.speakerNames)
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
            switch mode {
            case .all: await meetingStore.refresh(force: true)
            case .trash: await meetingStore.refreshTrash()
            }
        }
    }

    private var contentKey: String {
        "\(mode.rawValue)|\(owner.rawValue)|\(filterLabelID?.uuidString ?? "")"
    }

    private static let contentFade = Animation.easeInOut(duration: 0.2)

    @ViewBuilder
    private var content: some View {
        switch (mode, currentLoadState) {
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
        mode == .all ? meetingStore.loadState : meetingStore.trashState
    }

    private var normalizedQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func filtered(_ rows: [Meeting]) -> [Meeting] {
        var result = rows
        if mode == .all, let filterLabelID {
            let ids = labelStore.meetingIDs(withLabel: filterLabelID)
            result = result.filter { ids.contains($0.id) }
        }
        if mode == .all {
            switch owner {
            case .hidden:
                result = result.filter(meetingStore.isHidden)
            case .everyone:
                result = result.filter { !meetingStore.isHidden($0) }
            case .mine, .shared:
                let wantsShared = owner == .shared
                result = result.filter {
                    !meetingStore.isHidden($0) && meetingStore.isSharedWithMe($0) == wantsShared
                }
            }
        }
        let q = normalizedQuery
        if q.isEmpty { return result }
        return result.filter { meeting in
            meeting.matches(q)
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

    /// Carries the action, not directions to it: the panel this used to point
    /// at isn't on screen at launch, so "hit record on the floating panel" was
    /// an instruction with nothing to follow it.
    private var emptyAllState: some View {
        VStack(spacing: 14) {
            Image("nc-inbox-arrow-down")
                .icon(36)
                .foregroundStyle(Theme.Palette.muted)
            Text("No sessions yet.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Start one and Nod listens, then hands you a recap when you're done.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Button(action: onStartCapture) {
                Text("Start your first session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Text("Opens the capture panel — meeting, voice note or media. \(panelShortcut) brings it up any time.")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var emptyTrashState: some View {
        VStack(spacing: 14) {
            Image("nc-trash")
                .icon(32)
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
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 12) {
            Image("nc-magnifier")
                .icon(28)
                .foregroundStyle(Theme.Palette.muted)
            // An empty project is not a search that found nothing. Saying "no
            // matches for" with nothing after it reads as a bug, and it is the
            // sentence somebody sees the moment a folder stops being shared.
            Text(query.isEmpty ? "Nothing in this project" : "No matches for \u{201C}\(query)\u{201D}")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Image("nc-triangle-warning")
                .icon(28)
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
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Lists

    private func allList(_ rows: [Meeting]) -> some View {
        List(rows) { meeting in
            let isRecording = meeting.id == meetingStore.recordingMeetingID
            MeetingRow(
                meeting: meeting,
                mode: .all,
                isUnsynced: meetingStore.unsyncedMeetingIDs.contains(meeting.id),
                isRecording: isRecording,
                isSharedWithMe: meetingStore.isSharedWithMe(meeting)
            )
            .onTapGesture { onOpen(meeting) }
            .accessibilityAddTraits(.isButton)
            .listRowInsets(MeetingRow.rowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Palette.border)
            .contextMenu {
                // Nothing to offer on somebody else's session. The row-level
                // policies scope both writes to the owner, so a Delete here only
                // ever removed it from this window until the next refresh put it
                // back — and on the phone it never left at all.
                if meetingStore.isSharedWithMe(meeting) {
                    // Not Delete: the session is its owner's. This takes it out
                    // of this account's list and leaves everything else alone.
                    if meetingStore.isHidden(meeting) {
                        Button {
                            Task { await performUnhide(meeting) }
                        } label: {
                            IconLabel(title: "Show in my list", icon: "nc-eye")
                        }
                    } else {
                        Button {
                            Task { await performHide(meeting) }
                        } label: {
                            IconLabel(title: "Hide from my list", icon: "nc-eye-closed")
                        }
                    }
                } else {
                    Button {
                        Task { await performSoftDelete(meeting) }
                    } label: {
                        IconLabel(title: "Delete", icon: "nc-trash")
                    }
                    Button(role: .destructive) {
                        pendingHardDelete = meeting
                    } label: {
                        IconLabel(title: "Delete Forever", icon: "nc-trash")
                    }
                    .disabled(isRecording)
                    .help(isRecording ? "This meeting is still recording." : "")
                }
            }
        }
        .listStyle(.plain)
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
                    IconLabel(title: "Delete Forever", icon: "nc-trash")
                }
            }
            .listRowInsets(MeetingRow.rowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Palette.border)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func performHide(_ meeting: Meeting) async {
        do {
            try await meetingStore.hide(meeting)
        } catch {
            Log.ui.error("hide failed: \(error.localizedDescription)")
        }
    }

    private func performUnhide(_ meeting: Meeting) async {
        do {
            try await meetingStore.unhide(meeting.id)
        } catch {
            Log.ui.error("unhide failed: \(error.localizedDescription)")
        }
    }

    private func performSoftDelete(_ meeting: Meeting) async {
        do {
            try await meetingStore.softDelete(meeting)
        } catch {
            Log.ui.error("softDelete failed: \(error.localizedDescription)")
        }
    }

    private var hardDeleteAlertVisible: Binding<Bool> {
        .isPresented(by: $pendingHardDelete)
    }
}

// MARK: - Row

private struct MeetingRow: View {
    enum Mode { case all, trash }

    let meeting: Meeting
    let mode: Mode
    var isUnsynced: Bool = false
    var isRecording: Bool = false
    /// Reached this list through a folder somebody shared. Said plainly, because
    /// a session you did not record sitting unmarked among the ones you did is
    /// the kind of quiet wrongness people only notice after acting on it.
    var isSharedWithMe: Bool = false
    var onRestore: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let hoverInset: CGFloat = 10
    static let rowInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            kindIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.displayTitle(dateFormatter: Meeting.listDateFormatter))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if isSharedWithMe {
                        Text("Shared")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Theme.Palette.surfaceStrong)
                            )
                    }
                    Spacer(minLength: 0)
                    trailingMeta
                        .opacity(showRestore ? 0 : 1)
                        .overlay(alignment: .trailing) {
                            restoreButton
                                .revealOnHover(showRestore, reduceMotion: reduceMotion, anchor: .trailing)
                        }
                }

                Text(meeting.summaryPreview)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                knowledge
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Self.hoverInset)
        .hoverHighlight(isHovering, reduceMotion: reduceMotion)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var showRestore: Bool {
        mode == .trash && isHovering
    }

    /// What Nod took out of the session, under what the session was about. The
    /// third level on the card, and deliberately the quietest of the three —
    /// title, then gist, then what it yielded.
    @ViewBuilder private var knowledge: some View {
        let counts = SessionKnowledge.of(meeting)
        if !counts.isEmpty {
            Text(counts.summary)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 1)
        }
    }

    private var trailingMeta: some View {
        HStack(spacing: 8) {
            if isRecording {
                StatusFlagPill(text: "Recording", color: Theme.Palette.danger) {
                    Circle().frame(width: 6, height: 6)
                }
            }
            if isUnsynced, mode == .all {
                StatusFlagPill(text: "Not synced", color: Theme.Palette.warning) {
                    Image("nc-refresh-2").icon(9)
                }
                .help("Saved on this device — will finish syncing automatically.")
            }
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

    private var restoreButton: some View {
        Button {
            onRestore?()
        } label: {
            HStack(spacing: 4) {
                Image("nc-arrow-dotted-rotate-anticlockwise")
                    .icon(10)
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

    private var kindIcon: some View {
        Image(meeting.kind.icon)
            .icon(12)
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

    private static func relativeTrashedLabel(for date: Date) -> String {
        "trashed " + Meeting.ago(date)
    }
}

/// Shared shape for the row's "flag" badges (recording live, not yet synced)
/// — a leading glyph plus a label, tinted the same color throughout including
/// a soft capsule fill. Not used for the language pill below: that one has no
/// leading glyph and a flat surface fill, different enough that folding it in
/// here would trade one duplication for a pile of unused parameters.
private struct StatusFlagPill<Glyph: View>: View {
    let text: String
    let color: Color
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        HStack(spacing: 4) {
            glyph()
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

/// One applied filter, and the way out of it.
///
/// A chip that is only ever drawn when its filter is on — the list's default
/// state carries no filter chrome at all. The swatch is present for a project
/// and absent for everything else, which is what tells the two apart at a
/// glance without a second label saying "project".
struct FilterChip: View {
    let title: String
    var color: Color?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image("nc-circle-xmark")
                    .icon(10)
            }
            .buttonStyle(.plain)
            .help("Remove this filter")
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.8))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
        )
        .linkCursor()
    }
}
