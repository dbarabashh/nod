import SwiftUI

/// Editable view of a single meeting — title + summary (autosaved on a
/// 1-second debounce) plus a read-only Transcript tab that lazy-loads
/// from `meeting_transcripts` on first open.
struct MeetingDetailView: View {
    let meeting: Meeting

    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss

    @State private var editableTitle: String = ""
    @State private var editableSummary: String = ""
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var copyFlash: Bool = false
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
    /// LLM. Drives the loading placeholder in the Summary tab and gates
    /// every affordance that needs a real row (edit, copy, transcript
    /// load, server-side save, soft-delete).
    private var isGenerating: Bool {
        meetingStore.generatingSummaryIDs.contains(meeting.id)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                metadataTable
                tabBar
                subToolbar
                Divider().overlay(Theme.Palette.border)
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Palette.bg.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .toolbar { toolbarContent }
        .onAppear {
            editableTitle = current.title ?? ""
            editableSummary = current.summary
        }
        .onChange(of: selectedTab) { tab in
            if tab == .transcript, !isGenerating, case .idle = transcriptLoad {
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
            if selectedTab == .transcript, case .idle = transcriptLoad {
                Task { await loadTranscript() }
            }
        }
        .onDisappear(perform: flushPendingSaveOnDisappear)
    }

    // MARK: - Title

    @ViewBuilder
    private var titleField: some View {
        if isGenerating {
            Text("Generating title…")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: .placeholder)
        } else {
            TextField("Meeting title", text: $editableTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                .onChange(of: editableTitle) { _ in scheduleSave() }
        }
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
                label: "Language",
                value: AnyView(languageChip)
            )
        }
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
                .disabled(isGenerating)
                .opacity(isGenerating ? 0.4 : 1)
                subToolbarDivider
                Button(action: copyAll) {
                    subToolbarLabel(
                        systemImage: copyFlash ? "checkmark" : "doc.on.doc",
                        text: copyFlash ? "Copied" : "Copy summary"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
                .opacity(isGenerating ? 0.4 : 1)
                Spacer(minLength: 0)
                if !isGenerating {
                    saveIndicator
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 12) {
                subToolbarItem(systemImage: "character", label: meeting.language.uppercased())
                Spacer(minLength: 0)
            }
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
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(Theme.Palette.ink)
            Text("Generating summary…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("This usually takes a few seconds.")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if isGenerating {
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(Theme.Palette.muted)
                Text("Transcript will appear once the summary is ready.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
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
        case .loaded(let records):
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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(records) { record in
                        transcriptRow(record)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
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

    private func transcriptRow(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(sourceLabel(record.source))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(sourceBackground(record.source))
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

    private func sourceLabel(_ source: String) -> String {
        TranscriptSource(rawValue: source)?.label.uppercased() ?? source.uppercased()
    }

    private func sourceBackground(_ source: String) -> Color {
        switch TranscriptSource(rawValue: source) {
        case .me:   return Theme.Palette.violet.opacity(0.18)
        case .them: return Theme.Palette.cyan.opacity(0.18)
        case .none: return Theme.Palette.surface
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func loadTranscript() async {
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
        case .failed(let detail):
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

    // MARK: - Window toolbar (delete only — copy/edit moved into sub-toolbar)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive, action: deleteMeeting) {
                Image(systemName: "trash")
            }
            .help(isGenerating
                  ? "Available once the summary is ready"
                  : "Move to Trash")
            // Soft-delete hits the server `soft_delete_meeting` RPC,
            // which would 404 for a meeting that hasn't been inserted
            // yet. Re-enables the moment the row lands.
            .disabled(isDeleting || isGenerating)
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        if isGenerating { return "New meeting" }
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return current.displayTitle(dateFormatter: Self.dateFormatter)
    }

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
        guard !isGenerating else { return }
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
        guard isDirty, !isDeleting else { return }
        Task { await performSave() }
    }

    // MARK: - Delete

    private func deleteMeeting() {
        isDeleting = true
        saveTask?.cancel()
        let snapshot = meeting
        Task {
            do {
                try await meetingStore.softDelete(snapshot)
                await MainActor.run { dismiss() }
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
        let payload: String
        if titleLine.isEmpty {
            payload = "\(date)\n\n\(editableSummary)"
        } else {
            payload = "\(titleLine)\n\(date)\n\n\(editableSummary)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        withAnimation(.easeOut(duration: 0.15)) { copyFlash = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { copyFlash = false }
            }
        }
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
