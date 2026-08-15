import SwiftUI
import UniformTypeIdentifiers

/// Editable view of a single meeting — title + summary (autosaved on a
/// 1-second debounce) plus a read-only Transcript tab that lazy-loads
/// from `meeting_transcripts` on first open.
struct MeetingDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var summaryRegeneration: SummaryRegeneration
    @EnvironmentObject private var analytics: ProductAnalytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editableTitle: String = ""
    @State private var editableSummary: String = ""
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var copyFlash: Bool = false
    /// Drives the Share button: idle → sharing → copied (transient) or failed
    /// (transient). Mirrors `SaveState`; a share is summary-only and revocable.
    @State private var shareState: ShareState = .idle
    /// Drives the Export button: idle → exporting → saved / failed (transient).
    @State private var exportState: ExportState = .idle
    /// True while there are pending edits the user has typed but the
    /// debounce hasn't fired yet (or a save is in flight). Used by
    /// `.onDisappear` so a close-mid-typing still flushes the latest
    /// version instead of losing the unwritten characters.
    @State private var isDirty: Bool = false
    /// True while the soft-delete is in-flight, OR after the user
    /// confirmed delete — used to suppress the `.onDisappear` save flush
    /// so we don't undo the delete by saving the local buffer right after.
    @State private var isDeleting: Bool = false
    @State private var isEditingSummary: Bool = false
    @State private var selectedTab: Tab = .summary
    @State private var transcriptLoad: TranscriptLoadState = .idle
    @State private var showLabelPicker = false

    enum Tab: Hashable {
        case summary
        case transcript
    }

    private enum TranscriptLoadState {
        case idle
        case loading
        case loaded([TranscriptRecord])
        case failed(String)
    }

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private enum ShareState: Equatable {
        case idle
        case sharing
        case copied
        case failed
    }

    private enum ExportState: Equatable {
        case idle
        case exporting
        case saved
        case failed
    }

    private static let createdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM, HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static let endTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Live meeting from the store — picks up the title + summary that
    /// the end-of-meeting flow writes via `applyGenerated` after the LLM
    /// returns. Falls back to the captured `meeting` value when the store
    /// hasn't loaded yet (deep-link or refresh race).
    private var current: Meeting {
        meetingStore.byID[meeting.id] ?? meeting
    }

    /// True while ContentView's post-meeting Task is still waiting on the
    /// LLM. Drives the loading placeholder in the Summary tab.
    private var isGenerating: Bool {
        meetingStore.generatingSummaryIDs.contains(meeting.id)
    }

    /// True until the generated meeting row and transcript have finished their
    /// first persistence pass.
    private var isFinalizing: Bool {
        meetingStore.finalizingMeetingIDs.contains(meeting.id)
    }

    /// True while this line's speaker is still being decided. Scoped to the
    /// remote side: the user's own mic is a single known voice and is never
    /// clustered, so its chip is final the moment the line exists.
    private func isResolvingSpeakers(_ record: TranscriptRecord) -> Bool {
        TranscriptSource(rawValue: record.source) == .them
            && meetingStore.resolvingSpeakerIDs.contains(meeting.id)
    }

    /// Finished generating but still waiting on the server (durable outbox).
    /// Gated on `!isFinalizing` so the first-pass persistence shows its own
    /// "Finishing…" state, not a sync warning.
    private var isUnsynced: Bool {
        !isFinalizing && meetingStore.unsyncedMeetingIDs.contains(meeting.id)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                titleRow
                if !isFinalizing { labelsRow }
                metadataTable
                tabBar
                subToolbar
                Divider().overlay(Theme.Palette.border)
                content
                if selectedTab == .summary, !isFinalizing {
                    ActionItemsView(meeting: meeting)
                    RelatedSessionsView(meeting: meeting)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tooltipContainer()
        .background(Color.clear)
        .navigationTitle("")
        .onAppear {
            editableTitle = current.title ?? ""
            editableSummary = current.summary
            recordSummaryViewedIfRendered()
        }
        .onChange(of: selectedTab) { tab in
            if tab == .transcript, !isFinalizing, case .idle = transcriptLoad {
                Task { await loadTranscript() }
            }
            if tab == .transcript {
                analytics.recordMeetingInteraction(
                    .transcriptViewed,
                    contentType: .transcript,
                    meeting: current,
                    outcome: .viewed,
                    oncePerSession: "transcript:\(meeting.id.uuidString)"
                )
            } else {
                recordSummaryViewedIfRendered()
            }
        }
        .onChange(of: isGenerating) { generating in
            // Generation transition is the ONLY moment we sync
            // current.summary/title into the editors. A body-level
            // `.onChange(of: current.summary)` would also fire after
            // every autosave round-trip and clobber typing the user
            // did during the server PATCH (`abc` saved, user typed
            // `def` during the 300ms roundtrip → onChange overwrites
            // `abcdef` with the stale `abc`).
            guard !generating else { return }
            if editableSummary != current.summary {
                editableSummary = current.summary
            }
            let liveTitle = current.title ?? ""
            if editableTitle != liveTitle {
                editableTitle = liveTitle
            }
            recordSummaryViewedIfRendered()
        }
        .onChange(of: isFinalizing) { finalizing in
            if finalizing {
                if selectedTab == .transcript { transcriptLoad = .idle }
                return
            }
            if selectedTab == .transcript, shouldLoadTranscriptAfterFinalizing {
                Task { await loadTranscript() }
            }
            recordSummaryViewedIfRendered()
        }
        .onDisappear(perform: flushPendingSaveOnDisappear)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            backButton
            titleField
            deleteButton
        }
    }

    /// The session is presented as a sheet over the screen it was opened from,
    /// so this closes rather than navigates back.
    private var backButton: some View {
        Button(action: onClose) {
            Image("nc-xmark")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
                .iconButtonChrome()
        }
        .buttonStyle(.plain)
        .help("Close (esc)")
        .linkCursor()
    }

    /// Delete lives here, in the content, rather than the window toolbar — a
    /// `.primaryAction` item lands at the far right of the full-width window
    /// toolbar, which placed it over the chat dock instead of this pane.
    private var deleteButton: some View {
        Button(role: .destructive, action: deleteMeeting) {
            Image("nc-trash")
                .icon(13)
                .foregroundStyle(Theme.Palette.muted)
                .iconButtonChrome()
        }
        .buttonStyle(.plain)
        .help(isFinalizing ? "Available once the meeting is saved" : "Move to Trash")
        // Soft-delete hits the server `soft_delete_meeting` RPC, which would
        // 404 for a meeting that hasn't been inserted yet. Re-enables the
        // moment the row lands.
        .disabled(isDeleting || isFinalizing)
        .opacity(isFinalizing ? 0.4 : 1)
        .linkCursor()
    }

    @ViewBuilder
    private var titleField: some View {
        if isGenerating {
            Text("Generating title…")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: .placeholder)
        } else {
            TextField("Meeting title", text: $editableTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: editableTitle) { _ in scheduleSave() }
                .disabled(isFinalizing)
        }
    }

    // MARK: - Labels

    private var labelsRow: some View {
        let assigned = labelStore.labels(for: meeting.id)
        return HStack(spacing: 8) {
            Button { showLabelPicker = true } label: {
                HStack(spacing: 4) {
                    Image("nc-tag")
                        .icon(10)
                    Text(assigned.isEmpty ? "Add to folder" : "Folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.Palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help("Add or remove folders")
            .popover(isPresented: $showLabelPicker, arrowEdge: .bottom) {
                LabelPickerPopover(meetingID: meeting.id)
            }

            if !assigned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(assigned) { label in
                            LabelChip(label: label) { removeLabel(label) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func removeLabel(_ label: SessionLabel) {
        var set = labelStore.assignments[meeting.id] ?? []
        set.remove(label.id)
        Task { try? await labelStore.setLabels(set, for: meeting.id) }
    }

    // MARK: - Metadata table

    private var metadataTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow(
                label: "Created",
                value: AnyView(
                    Text(Self.createdFormatter.string(from: current.startedAt) +
                        " → " +
                        Self.endTimeFormatter.string(from: current.endedAt))
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                )
            )
            metadataRow(
                label: "Duration",
                value: AnyView(
                    HStack(spacing: 6) {
                        Image("nc-stopwatch")
                            .icon(11)
                            .foregroundStyle(Theme.Palette.muted)
                        Text(meetingDurationString(from: current.startedAt, to: current.endedAt))
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                    }
                )
            )
            metadataRow(
                label: "Nod language",
                value: AnyView(languageChip)
            )
            if isUnsynced {
                metadataRow(
                    label: "Sync",
                    value: AnyView(syncStatusChip)
                )
            }
        }
    }

    /// Shown only while the meeting is still queued in the durable outbox. The
    /// recap is safe on this device; the chip just explains why it isn't on the
    /// server yet (e.g. offline). Retry is driven by the main-window toast.
    private var syncStatusChip: some View {
        HStack(spacing: 4) {
            Image("nc-refresh-2")
                .icon(10)
            Text("Saved on this device — syncing…")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.warning)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.warning.opacity(0.12))
                .overlay(Capsule().stroke(Theme.Palette.warning.opacity(0.35), lineWidth: 0.5))
        )
    }

    private func metadataRow(label: String, value: AnyView) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 84, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }

    private var languageChip: some View {
        Text(meeting.language.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(Theme.Palette.ink.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
            )
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 22) {
            tabButton(.summary, label: "Summary")
            tabButton(.transcript, label: "Transcript")
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 0.5)
                .offset(y: 6)
        }
        .padding(.bottom, 6)
    }

    private func tabButton(_ tab: Tab, label: String) -> some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) { selectedTab = tab }
        } label: {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab
                        ? Theme.Palette.ink
                        : Theme.Palette.muted)
                Rectangle()
                    .fill(selectedTab == tab ? Theme.Palette.ink : Color.clear)
                    .frame(height: 1.5)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub-toolbar (above content)

    @ViewBuilder
    private var subToolbar: some View {
        if selectedTab == .summary {
            // The buttons live in a horizontal scroll so the toolbar never forces
            // a minimum width on the detail column — otherwise, widening the chat
            // dock would push this column past the window and slide the dock off
            // the right edge. At normal widths everything fits and nothing
            // scrolls; the save indicator stays pinned to the trailing edge.
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        SubToolbarItem(icon: "nc-language", label: meeting.language.uppercased())
                        SubToolbarDivider()
                        Button(action: { isEditingSummary.toggle() }) {
                            SubToolbarLabel(
                                icon: isEditingSummary ? "nc-check" : "nc-pen-writing",
                                text: isEditingSummary ? "Done" : "Edit"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isFinalizing)
                        .opacity(isFinalizing ? 0.4 : 1)
                        .linkCursor()
                        SubToolbarDivider()
                        copyButton("Copy", isActive: !isGenerating, action: copyAll)
                        SubToolbarDivider()
                        Button(action: shareLink) {
                            SubToolbarLabel(
                                icon: shareIcon,
                                text: shareLabel
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isFinalizing || shareState == .sharing)
                        .opacity(isFinalizing ? 0.4 : 1)
                        .linkCursor()
                        SubToolbarDivider()
                        MeetingShareButton(meetingID: meeting.id, isReady: meetingStore.isPersisted(meeting.id))
                        SubToolbarDivider()
                        exportButton
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !isFinalizing {
                    saveIndicator
                        .fixedSize()
                }
            }
            .padding(.vertical, 2)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SubToolbarItem(icon: "nc-language", label: meeting.language.uppercased())
                    SubToolbarDivider()
                    copyButton("Copy", isActive: transcriptIsCopyable, action: copyTranscript)
                    SubToolbarDivider()
                    exportButton
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exportButton: some View {
        Button(action: exportMarkdown) {
            SubToolbarLabel(icon: exportIcon, text: exportLabel)
        }
        .buttonStyle(.plain)
        .disabled(isFinalizing || isGenerating || exportState == .exporting)
        .opacity(isFinalizing || isGenerating ? 0.4 : 1)
        .linkCursor()
    }

    private var exportIcon: String {
        switch exportState {
        case .idle, .exporting: "nc-inbox-arrow-down"
        case .saved: "nc-check"
        case .failed: "nc-triangle-warning"
        }
    }

    private var exportLabel: String {
        switch exportState {
        case .idle: "Export"
        case .exporting: "Exporting…"
        case .saved: "Saved"
        case .failed: "Try again"
        }
    }

    private var transcriptIsCopyable: Bool {
        if case let .loaded(records) = transcriptLoad { return !records.isEmpty }
        return false
    }

    private var shouldLoadTranscriptAfterFinalizing: Bool {
        switch transcriptLoad {
        case .idle:
            true
        case let .loaded(records):
            records.isEmpty
        case .loading, .failed:
            false
        }
    }

    /// Shared copy button for the summary and transcript sub-toolbars. Both
    /// flash the same `copyFlash` confirmation (the tabs are never visible at
    /// once), differing only in label and what gates them.
    private func copyButton(_ text: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SubToolbarLabel(
                icon: copyFlash ? "nc-check" : "nc-files-2",
                text: copyFlash ? "Copied" : text
            )
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .opacity(isActive ? 1 : 0.4)
        .linkCursor()
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .summary: summaryContent
        case .transcript: transcriptContent
        }
    }

    /// Partial recap markdown streamed in while the summary generates, or nil
    /// before the first section closes. Drives the live fill-in below.
    private var streamingSummary: String? {
        let partial = meetingStore.streamingSummaries[meeting.id]
        return (partial?.isEmpty == false) ? partial : nil
    }

    @ViewBuilder
    private var summaryContent: some View {
        if isGenerating {
            if let partial = streamingSummary {
                streamingSummaryView(partial)
            } else {
                generatingSummaryPlaceholder
            }
        } else if case let .running(partial) = summaryRegeneration.state(for: meeting.id) {
            if let partial {
                streamingSummaryView(partial)
            } else {
                generatingSummaryPlaceholder
            }
        } else if !isEditingSummary, current.lacksRecap {
            missingSummaryState
        } else if isEditingSummary {
            TextEditor(text: $editableSummary)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 320)
                .padding(10)
                .background(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: editableSummary) { _ in scheduleSave() }
        } else {
            Text(renderRecapMarkdown(editableSummary))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Live recap fill-in: the rendered partial markdown plus the same
    /// thinking indicator, so the user watches sections appear while the model
    /// is still writing the rest.
    private func streamingSummaryView(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renderRecapMarkdown(markdown))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ThinkingIndicator(script: [
                "Writing the recap…",
                "Capturing decisions & action items…",
                "Almost there…"
            ])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown when the meeting kept its transcript but never got a recap — the
    /// recap is the only thing missing, so the offer is to rebuild it.
    private var missingSummaryState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.summary)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: regenerateSummary) {
                SubToolbarLabel(icon: "nc-refresh-2", text: "Generate summary")
            }
            .buttonStyle(.plain)
            // A meeting still queued in the outbox would have the regenerated
            // recap overwritten by the next drain — the WAL copy still holds the
            // note, and it wins over the cache until the push lands.
            .disabled(isFinalizing || isUnsynced)
            .opacity(isFinalizing || isUnsynced ? 0.4 : 1)
            .help(isUnsynced ? "Available once the meeting finishes syncing" : "Rebuild the summary from the saved transcript")
            .linkCursor()
            if case let .failed(message) = summaryRegeneration.state(for: meeting.id) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generatingSummaryPlaceholder: some View {
        // Same bouncing-dots indicator as the in-call chat — the label walks a
        // few stages and holds on the last, so the wait reads as live activity
        // instead of a spinner that promises a fixed "few seconds".
        ThinkingIndicator(script: [
            "Generating summary…",
            "Pulling out key points…",
            "Capturing decisions & action items…",
            "Almost there…"
        ])
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if isFinalizing {
            // The first transcript fetch waits until the meeting row and
            // transcript insert have completed, so it cannot cache an early
            // empty result for the just-finished meeting.
            ThinkingIndicator(script: [
                "Preparing transcript…",
                "Saving what was said…",
                "Almost there…"
            ])
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        } else {
            transcriptLoadedContent
        }
    }

    @ViewBuilder
    private var transcriptLoadedContent: some View {
        switch transcriptLoad {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 40)
        case let .loaded(records):
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image("nc-msg-writing")
                        .icon(22)
                        .foregroundStyle(Theme.Palette.muted)
                    Text("No transcript saved for this meeting.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(records) { record in
                        transcriptRow(record)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .failed(message):
            VStack(spacing: 8) {
                Image("nc-triangle-warning")
                    .icon(18)
                    .foregroundStyle(Theme.Palette.warning)
                Text("Couldn't load transcript")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await loadTranscript() } }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func transcriptRow(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SpeakerChip(
                    label: record.displayLabel(names: current.speakerNames),
                    tint: speakerBackground(record),
                    isResolving: isResolvingSpeakers(record)
                )
                Text(Self.timeFormatter.string(from: record.ts))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(record.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mic (`me`) is violet; the remote party (`them`) is cyan.
    private func speakerBackground(_ record: TranscriptRecord) -> Color {
        switch TranscriptSource(rawValue: record.source) {
        case .me: Theme.Palette.violet.opacity(0.18)
        case .them: Theme.Palette.cyan.opacity(0.18)
        case nil: Theme.Palette.surface
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func loadTranscript() async {
        guard !isFinalizing else { return }
        transcriptLoad = .loading
        do {
            let records = try await meetingStore.fetchTranscript(meetingID: meeting.id)
            transcriptLoad = .loaded(records)
        } catch {
            Log.ui.error("MeetingDetailView fetchTranscript failed: \(error.localizedDescription)")
            transcriptLoad = .failed(error.localizedDescription)
        }
    }

    private func regenerateSummary() {
        Task {
            guard let updated = await summaryRegeneration.run(for: current) else { return }
            editableSummary = updated.summary
            editableTitle = updated.title ?? ""
        }
    }

    // MARK: - Save indicator

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.Palette.muted)
                Text("Saving…")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case .saved:
            HStack(spacing: 4) {
                Image("nc-circle-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.success)
                Text("Saved")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case let .failed(detail):
            HStack(spacing: 4) {
                Image("nc-triangle-warning")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.warning)
                Text("Couldn't save")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
                    .help(detail)
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Autosave (debounced) + manual copy

    private func scheduleSave() {
        // The meeting isn't on the server yet during generation — a
        // PATCH would 404. The detail view also disables every input
        // path that could trigger this, so reaching here while
        // generating means SwiftUI fired .onChange for an internal sync
        // we don't want persisted.
        guard !isFinalizing else { return }
        saveTask?.cancel()
        isDirty = true
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveState = .saving
            await performSave()
        }
    }

    private func performSave() async {
        guard !isFinalizing else { return }
        let titleTrimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // From `current`, not the captured `meeting`: the latter is a snapshot
        // from when the view opened, so saving an edit after a generation (or a
        // manual regeneration) would write its stale nil recap back over the
        // structured state in the cache.
        let updated = current.updating(
            title: titleTrimmed.isEmpty ? nil : titleTrimmed,
            summary: editableSummary
        )
        do {
            try await meetingStore.update(updated)
            saveState = .saved
            isDirty = false
        } catch {
            Log.ui.error("MeetingDetailView save failed: \(error.localizedDescription)")
            saveState = .failed(error.localizedDescription)
        }
    }

    private func flushPendingSaveOnDisappear() {
        saveTask?.cancel()
        guard isDirty, !isDeleting, !isFinalizing else { return }
        Task { await performSave() }
    }

    // MARK: - Delete

    private func deleteMeeting() {
        guard !isFinalizing else { return }
        isDeleting = true
        saveTask?.cancel()
        let snapshot = meeting
        Task {
            do {
                try await meetingStore.softDelete(snapshot)
                await MainActor.run { onClose() }
            } catch {
                Log.ui.error("MeetingDetailView delete failed: \(error.localizedDescription)")
                await MainActor.run {
                    isDeleting = false
                    saveState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func copyAll() {
        let titleLine = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Self.dateFormatter.string(from: meeting.startedAt)
        let payload = if titleLine.isEmpty {
            "\(date)\n\n\(editableSummary)"
        } else {
            "\(titleLine)\n\(date)\n\n\(editableSummary)"
        }
        copyAndFlash(payload)
    }

    private func recordSummaryViewedIfRendered() {
        guard selectedTab == .summary,
              !isGenerating,
              !isFinalizing,
              !current.lacksRecap
        else { return }
        analytics.recordMeetingInteraction(
            .summaryViewed,
            contentType: .summary,
            meeting: current,
            outcome: .viewed,
            oncePerSession: "summary:\(meeting.id.uuidString)"
        )
    }

    /// Writes `text` to the clipboard and runs the shared copy-button flash.
    /// Used by both the summary and transcript copy buttons.
    private func copyAndFlash(_ text: String) {
        NSPasteboard.copyText(text)
        analytics.recordMeetingInteraction(
            .contentCopied,
            contentType: selectedTab == .summary ? .summary : .transcript,
            meeting: current,
            outcome: .success
        )
        Task { await flashConfirmation(set: { copyFlash = true }, reset: { copyFlash = false }, for: 1.5) }
    }

    /// Copies the loaded transcript as plain text, one line per utterance:
    /// `[HH:MM:SS] Me: …`. No-op until the transcript has loaded (the button
    /// is disabled in that state).
    private func copyTranscript() {
        guard case let .loaded(records) = transcriptLoad, !records.isEmpty else { return }
        let payload = records
            .map { record in
                "[\(Self.timeFormatter.string(from: record.ts))] \(record.displayLabel(names: current.speakerNames)): \(record.text)"
            }
            .joined(separator: "\n")
        copyAndFlash(payload)
    }

    private var shareIcon: String {
        switch shareState {
        case .idle, .sharing: "nc-link"
        case .copied: "nc-check"
        case .failed: "nc-triangle-warning"
        }
    }

    private var shareLabel: String {
        switch shareState {
        case .idle: "Copy link"
        case .sharing: "Creating…"
        case .copied: "Copied"
        case .failed: "Try again"
        }
    }

    /// Mints (or reuses) a public share link for this meeting and drops it on
    /// the clipboard. The link is summary-only and revocable — sharing is an
    /// explicit action, never automatic. Errors flip the button to a transient
    /// "Try again" state rather than throwing a modal.
    private func shareLink() {
        guard !isFinalizing else { return }
        guard shareState != .sharing else { return }
        shareState = .sharing
        Task {
            do {
                let url = try await meetingStore.createShareURL(for: meeting)
                NSPasteboard.copyText(url.absoluteString)
                await flashConfirmation(set: { shareState = .copied }, reset: { shareState = .idle }, for: 1.8)
            } catch {
                Log.ui.error("share link failed: \(error.localizedDescription)")
                await flashConfirmation(set: { shareState = .failed }, reset: { shareState = .idle }, for: 2.5)
            }
        }
    }

    /// Exports the meeting to a local Obsidian-friendly `.md` file (YAML
    /// frontmatter + summary + transcript). Reuses the already-loaded
    /// transcript when present, otherwise fetches it. A data-ownership feature:
    /// the user picks where the file lands via the standard save panel.
    private func exportMarkdown() {
        guard !isFinalizing, !isGenerating, exportState != .exporting else { return }
        exportState = .exporting
        Task {
            let trimmedTitle = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let exportMeeting = current.updating(
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                summary: editableSummary
            )

            let records: [TranscriptRecord] = if case let .loaded(loaded) = transcriptLoad {
                loaded
            } else {
                await (try? meetingStore.fetchTranscript(meetingID: meeting.id)) ?? []
            }

            let tags = labelStore.labels(for: meeting.id).map(\.name)
            let actionItems = actionItemStore.items(forMeeting: meeting.id)
            let markdown = MeetingMarkdownExport.render(
                meeting: exportMeeting,
                transcript: records,
                tags: tags,
                actionItems: actionItems
            )

            let panel = NSSavePanel()
            panel.nameFieldStringValue = MeetingMarkdownExport.fileName(for: exportMeeting)
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.title = "Export meeting"

            guard panel.runModal() == .OK, let url = panel.url else {
                exportState = .idle
                return
            }

            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                analytics.recordMeetingInteraction(
                    .meetingExported,
                    contentType: .markdown,
                    meeting: current,
                    outcome: .success
                )
                await flashConfirmation(set: { exportState = .saved }, reset: { exportState = .idle }, for: 1.8)
            } catch {
                Log.ui.error("markdown export failed: \(error.localizedDescription)")
                await flashConfirmation(set: { exportState = .failed }, reset: { exportState = .idle }, for: 2.5)
            }
        }
    }
}

private func meetingDurationString(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes >= 60 {
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

// MARK: - Shared markdown helper

/// Inline-only parser so `**bold**` renders for section headers while line
/// breaks + literal `- ` bullets the LLM emits stay intact. Block-level
/// parsing would collapse the visual structure we actually want.
func renderRecapMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: source, options: options))
        ?? AttributedString(source)
}

/// The chrome of the sub-toolbar above a meeting's body: a read-only fact, a
/// tappable label, and the hairline between them. Their own types rather than
/// methods on the view — they read no state, and holding them inside the view
/// only made a body that SwiftLint had already stopped growing.
private struct SubToolbarItem: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(icon)
                .icon(11)
                .foregroundStyle(Theme.Palette.muted)
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .lineLimit(1)
        }
        .fixedSize()
    }
}

private struct SubToolbarLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(icon)
                .icon(11)
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
        .fixedSize()
    }
}

private struct SubToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: 0.5, height: 14)
    }
}
