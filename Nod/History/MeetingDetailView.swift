import SwiftUI

/// Editable view of a single meeting — title + summary (autosaved on a
/// 1-second debounce) plus a read-only Transcript tab that lazy-loads
/// from `meeting_transcripts` on first open.
struct MeetingDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var labelStore: LabelStore

    @State private var editableTitle: String = ""
    @State private var editableSummary: String = ""
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var copyFlash: Bool = false
    /// Drives the Share button: idle → sharing → copied (transient) or failed
    /// (transient). Mirrors `SaveState`; a share is summary-only and revocable.
    @State private var shareState: ShareState = .idle
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
        meetingStore.meetings.first(where: { $0.id == meeting.id }) ?? meeting
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

    private var transcriptSpeakerRevision: Int {
        meetingStore.transcriptSpeakerRevisions[meeting.id] ?? 0
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
                    RelatedSessionsView(meeting: meeting)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .navigationTitle("")
        .onAppear {
            editableTitle = current.title ?? ""
            editableSummary = current.summary
        }
        .onChange(of: selectedTab) { tab in
            if tab == .transcript, !isFinalizing, case .idle = transcriptLoad {
                Task { await loadTranscript() }
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
        }
        .onChange(of: isFinalizing) { finalizing in
            if finalizing {
                if selectedTab == .transcript { transcriptLoad = .idle }
                return
            }
            if selectedTab == .transcript, shouldLoadTranscriptAfterFinalizing {
                Task { await loadTranscript() }
            }
        }
        .onChange(of: transcriptSpeakerRevision) { _ in
            guard selectedTab == .transcript, !isFinalizing else { return }
            if case .loaded = transcriptLoad {
                Task { await loadTranscript() }
            }
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

    private var backButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
                .iconButtonChrome()
        }
        .buttonStyle(.plain)
        .help("Back to library")
        .linkCursor()
    }

    /// Delete lives here, in the content, rather than the window toolbar — a
    /// `.primaryAction` item lands at the far right of the full-width window
    /// toolbar, which placed it over the chat dock instead of this pane.
    private var deleteButton: some View {
        Button(role: .destructive, action: deleteMeeting) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .semibold))
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
                    Image(systemName: "tag")
                        .font(.system(size: 10, weight: .semibold))
                    Text(assigned.isEmpty ? "Add label" : "Label")
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
            .help("Add or remove labels")
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
                    Text(Self.createdFormatter.string(from: meeting.startedAt) +
                        " → " +
                        endTimeString(meeting.endedAt))
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                )
            )
            metadataRow(
                label: "Duration",
                value: AnyView(
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Theme.Palette.muted)
                        Text(durationString(from: meeting.startedAt, to: meeting.endedAt))
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
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
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
            withAnimation(.easeOut(duration: 0.15)) { selectedTab = tab }
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
            HStack(spacing: 12) {
                subToolbarItem(systemImage: "character", label: meeting.language.uppercased())
                subToolbarDivider
                Button(action: { isEditingSummary.toggle() }) {
                    subToolbarLabel(
                        systemImage: isEditingSummary ? "checkmark" : "square.and.pencil",
                        text: isEditingSummary ? "Done" : "Edit"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isFinalizing)
                .opacity(isFinalizing ? 0.4 : 1)
                .linkCursor()
                subToolbarDivider
                copyButton("Copy summary", isActive: !isGenerating, action: copyAll)
                subToolbarDivider
                Button(action: shareLink) {
                    subToolbarLabel(
                        systemImage: shareIcon,
                        text: shareLabel
                    )
                }
                .buttonStyle(.plain)
                .disabled(isFinalizing || shareState == .sharing)
                .opacity(isFinalizing ? 0.4 : 1)
                .linkCursor()
                Spacer(minLength: 0)
                if !isFinalizing {
                    saveIndicator
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 12) {
                subToolbarItem(systemImage: "character", label: meeting.language.uppercased())
                subToolbarDivider
                copyButton("Copy transcript", isActive: transcriptIsCopyable, action: copyTranscript)
                Spacer(minLength: 0)
            }
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

    private func subToolbarItem(systemImage: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
        }
    }

    private func subToolbarLabel(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .regular))
            Text(text)
                .font(.system(size: 12, weight: .regular))
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
    }

    /// Shared copy button for the summary and transcript sub-toolbars. Both
    /// flash the same `copyFlash` confirmation (the tabs are never visible at
    /// once), differing only in label and what gates them.
    private func copyButton(_ text: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            subToolbarLabel(
                systemImage: copyFlash ? "checkmark" : "doc.on.doc",
                text: copyFlash ? "Copied" : text
            )
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .opacity(isActive ? 1 : 0.4)
        .linkCursor()
    }

    private var subToolbarDivider: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: 0.5, height: 14)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .summary: summaryContent
        case .transcript: transcriptContent
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if isGenerating {
            generatingSummaryPlaceholder
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
                "Separating speakers…",
                "Labelling who said what…",
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
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                    Text("No transcript saved for this meeting.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                let numbered = TranscriptRecord.speakersAreNumbered(records)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(records) { record in
                        transcriptRow(record, numbered: numbered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .failed(message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
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

    private func transcriptRow(_ record: TranscriptRecord, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.displayLabel(numbered: numbered).uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(speakerBackground(record))
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

    /// Mic is always violet; each diarized remote speaker gets a distinct hue
    /// rotating around the wheel so "Them 1/2/3" are visually separable.
    private func speakerBackground(_ record: TranscriptRecord) -> Color {
        guard TranscriptSource(rawValue: record.source) == .them else {
            return TranscriptSource(rawValue: record.source) == .me
                ? Theme.Palette.violet.opacity(0.18)
                : Theme.Palette.surface
        }
        guard let speaker = record.speaker else { return Theme.Palette.cyan.opacity(0.18) }
        let hue = Double(speaker).truncatingRemainder(dividingBy: 8) / 8.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.9).opacity(0.22)
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.success)
                Text("Saved")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case let .failed(detail):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.warning)
                Text("Couldn't save")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
                    .help(detail)
            }
        }
    }

    // MARK: - Helpers

    private func endTimeString(_ end: Date) -> String {
        Self.endTimeFormatter.string(from: end)
    }

    private func durationString(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let m = seconds / 60
        let s = seconds % 60
        if m >= 60 {
            return String(format: "%dh %02dm", m / 60, m % 60)
        }
        return String(format: "%d:%02d", m, s)
    }

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
        let updated = meeting.updating(
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

    /// Writes `text` to the clipboard and runs the shared copy-button flash.
    /// Used by both the summary and transcript copy buttons.
    private func copyAndFlash(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Task { await flashConfirmation(set: { copyFlash = true }, reset: { copyFlash = false }, for: 1.5) }
    }

    /// Copies the loaded transcript as plain text, one line per utterance:
    /// `[HH:MM:SS] Me: …`. No-op until the transcript has loaded (the button
    /// is disabled in that state).
    private func copyTranscript() {
        guard case let .loaded(records) = transcriptLoad, !records.isEmpty else { return }
        let numbered = TranscriptRecord.speakersAreNumbered(records)
        let payload = records
            .map { record in
                "[\(Self.timeFormatter.string(from: record.ts))] \(record.displayLabel(numbered: numbered)): \(record.text)"
            }
            .joined(separator: "\n")
        copyAndFlash(payload)
    }

    private var shareIcon: String {
        switch shareState {
        case .idle, .sharing: "link"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var shareLabel: String {
        switch shareState {
        case .idle: "Share link"
        case .sharing: "Creating…"
        case .copied: "Link copied"
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                await flashConfirmation(set: { shareState = .copied }, reset: { shareState = .idle }, for: 1.8)
            } catch {
                Log.ui.error("share link failed: \(error.localizedDescription)")
                await flashConfirmation(set: { shareState = .failed }, reset: { shareState = .idle }, for: 2.5)
            }
        }
    }

    /// Apply a transient button confirmation: animate `set` in, hold for
    /// `seconds`, then animate `reset` back. Shared by the copy and share
    /// buttons so both flash identically.
    @MainActor
    private func flashConfirmation(set: () -> Void, reset: () -> Void, for seconds: Double) async {
        withAnimation(.easeOut(duration: 0.15), set)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        withAnimation(.easeOut(duration: 0.2), reset)
    }
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

private extension View {
    /// 30×30 surface tile with a hairline border — the detail header's icon-button chrome.
    func iconButtonChrome() -> some View {
        frame(width: 30, height: 30)
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
