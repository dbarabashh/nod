import SwiftUI

/// Editable view of a single meeting — full summary + title.
/// Autosaves on a 1-second debounce. The transcript is intentionally not
/// part of the persisted record (see Meeting.swift), so this view only
/// renders + edits summary + title.
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
    /// View vs edit mode for the summary. Default to view (rendered
    /// markdown) so users opening a past meeting see formatted text
    /// instead of literal `**Decisions made**` asterisks. Toolbar
    /// toggle flips to edit mode for raw text editing.
    @State private var isEditingSummary: Bool = false

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        // No outer ScrollView — TextEditor's NSTextView already brings its
        // own scroller, so nesting them produced two stacked scroll bars
        // ("double scroll" the user reported). Title + header stay pinned
        // at the top, the editor fills the rest and scrolls internally.
        VStack(alignment: .leading, spacing: 14) {
            titleField
            header
            summaryEditor
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bg.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .toolbar { toolbarContent }
        .onAppear {
            editableTitle = meeting.title ?? ""
            editableSummary = meeting.summary
        }
        .onDisappear(perform: flushPendingSaveOnDisappear)
    }

    // MARK: - Sections

    private var titleField: some View {
        TextField("Meeting title", text: $editableTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .onChange(of: editableTitle) { _ in scheduleSave() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(Self.dateFormatter.string(from: meeting.startedAt))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)

            Text("·")
                .foregroundStyle(Theme.Palette.muted)

            Text(durationString(from: meeting.startedAt, to: meeting.endedAt))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)

            Spacer(minLength: 0)

            saveIndicator

            Text(meeting.language.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
                )
        }
    }

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Summary")
            Group {
                if isEditingSummary {
                    TextEditor(text: $editableSummary)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                        .scrollContentBackground(.hidden)
                        .onChange(of: editableSummary) { _ in scheduleSave() }
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(renderRecapMarkdown(editableSummary))
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.Palette.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.Palette.muted)
            .textCase(.uppercase)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: { isEditingSummary.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: isEditingSummary ? "checkmark" : "square.and.pencil")
                    Text(isEditingSummary ? "Done" : "Edit")
                }
            }
            .help(isEditingSummary ? "Switch back to formatted view" : "Edit the summary")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: copyAll) {
                HStack(spacing: 6) {
                    Image(systemName: copyFlash ? "checkmark" : "doc.on.doc")
                    Text(copyFlash ? "Copied" : "Copy")
                }
            }
            .help("Copy title + date + summary to clipboard")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive, action: deleteMeeting) {
                Image(systemName: "trash")
            }
            .help("Move to Trash")
            .disabled(isDeleting)
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return meeting.displayTitle(dateFormatter: Self.dateFormatter)
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

    /// Cancel any pending save and schedule a new one ~1s after the last
    /// keystroke. The visible save indicator stays at its prior value
    /// during typing — the `.saving` flip happens AFTER the debounce so
    /// the chip doesn't flicker between every character.
    private func scheduleSave() {
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

    /// Flush any unsaved edits when the view leaves the hierarchy. Without
    /// this, closing the History window mid-typing (or navigating away
    /// before the 1s debounce fires) loses the most recent characters.
    /// Skipped when the view is leaving because the user just deleted —
    /// no point saving the buffer to a row that's heading for Trash.
    private func flushPendingSaveOnDisappear() {
        saveTask?.cancel()
        guard isDirty, !isDeleting else { return }
        // Fire-and-forget — the view is being torn down, but MeetingStore
        // outlives it on the AppDelegate so the PATCH completes regardless.
        Task { await performSave() }
    }

    // MARK: - Delete (issue #16)

    /// Soft-delete the meeting and pop back to the History list. The list
    /// shows the Undo toast that's already wired in HistoryView, so the
    /// user can recover without leaving the window.
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
        // Mirror the visible state — if the user cleared the title field,
        // don't sneak the date in as a fake title (the previous behaviour
        // produced a clipboard that didn't match what the editor showed).
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

        // Flash the toolbar button to "Copied" briefly.
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

/// Parses recap markdown: inline syntax only (so `**bold**` renders for
/// the section headers) while preserving line breaks + literal `- `
/// bullets the LLM emits. Block-level parsing would collapse the visual
/// structure we actually want. Used by both MeetingDetailView's preview
/// pane and ResponseCard's editable recap preview.
func renderRecapMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: source, options: options))
        ?? AttributedString(source)
}
