import SwiftUI

/// The sessions browser: search, All/Trash, the project filter, and the list
/// itself. Its own view rather than another 400 lines inside the window shell —
/// the shell's job is choosing which surface to show, not being one.
struct SessionsListView: View {
    /// Project filter, owned by the window: picking a project in the sidebar
    /// navigates here with it already applied.
    @Binding var filterLabelID: UUID?
    let onOpen: (Meeting) -> Void
    /// Same intent the sidebar's Capture button dispatches, minus the kind
    /// picker: the empty state offers one thing, and it's a meeting.
    let onStartCapture: () -> Void
    let panelShortcut: String

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var labelStore: LabelStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    @State private var segment: Segment = .all
    @State private var reindexProgress: ReindexProgress?
    @State private var pendingHardDelete: Meeting?

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
                Text(activeProject?.name ?? "Sessions")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if activeProject != nil {
                    Button { filterLabelID = nil } label: {
                        Text("Clear filter")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            searchField
            segmentBar
            labelFilterBar
            content
                .id(contentKey)
                .transition(.opacity)
        }
    }

    private var activeProject: SessionLabel? {
        guard let filterLabelID else { return nil }
        return labelStore.labels.first { $0.id == filterLabelID }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image("nc-magnifier")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
            TextField("Search sessions", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image("nc-circle-xmark")
                        .icon(12)
                        .foregroundStyle(Theme.Palette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
        )
        .frame(maxWidth: 280, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var segmentBar: some View {
        HStack(spacing: 8) {
            SegmentedControl(selection: $segment, animation: Self.contentFade)
                .frame(width: 200)
            Spacer(minLength: 12)
            listActions
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: segment) { new in
            if new == .trash, case .idle = meetingStore.trashState {
                Task { await meetingStore.refreshTrash() }
            }
        }
    }

    /// Browse by project. Only on the All segment, and only once the user has
    /// at least one — the sidebar carries the same list, this is the in-place
    /// filter for when you're already looking at sessions.
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
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 10)
        }
    }

    private var listActions: some View {
        HStack(spacing: 6) {
            if meetingStore.lastRefreshFailed, segment == .all {
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
            if segment == .all {
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
        let meetings = meetingStore.meetings
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
            switch segment {
            case .all: await meetingStore.refresh(force: true)
            case .trash: await meetingStore.refreshTrash()
            }
        }
    }

    private var contentKey: String {
        "\(segment.rawValue)|\(filterLabelID?.uuidString ?? "")"
    }

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
        VStack(spacing: 12) {
            Image("nc-magnifier")
                .icon(28)
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
                isRecording: isRecording
            )
            .onTapGesture { onOpen(meeting) }
            .accessibilityAddTraits(.isButton)
            .listRowInsets(MeetingRow.rowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Palette.border)
            .contextMenu {
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

    private func performSoftDelete(_ meeting: Meeting) async {
        do {
            try await meetingStore.softDelete(meeting)
        } catch {
            Log.ui.error("softDelete failed: \(error.localizedDescription)")
        }
    }

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
private struct SegmentedControl: View {
    @Binding var selection: SessionsListView.Segment
    let animation: Animation
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SessionsListView.Segment.allCases) { segment in
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
    var isUnsynced: Bool = false
    var isRecording: Bool = false
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
