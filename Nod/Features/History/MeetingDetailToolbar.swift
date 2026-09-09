import SwiftUI
import UniformTypeIdentifiers

/// The row of actions above a meeting's body: edit, copy, share, grant to a
/// team, export.
///
/// It owns the three transient button states because nothing outside it reads
/// them — the parent hands over the meeting as it stands on screen and the
/// transcript it already fetched, and gets back nothing but the edit toggle.
struct MeetingDetailToolbar: View {
    /// The meeting as the user has it on screen right now, not as it was last
    /// saved: Copy and Export write what is in the editors.
    let meeting: Meeting
    let tab: MeetingDetailView.Tab
    @Binding var isEditingSummary: Bool
    let isFinalizing: Bool
    let isGenerating: Bool
    let transcript: TranscriptLoadState
    /// Whose microphone `me` was, when that is not the person copying.
    var hostName: String?

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var analytics: ProductAnalytics

    /// Both tabs flash the same confirmation — they are never visible at once.
    @State private var copyFlash = false
    @State private var shareState: ShareState = .idle
    @State private var exportState: ExportState = .idle

    private enum ShareState: Equatable {
        case idle, sharing, copied, failed
    }

    private enum ExportState: Equatable {
        case idle, exporting, saved, failed
    }

    // The buttons live in a horizontal scroll so the toolbar never forces a
    // minimum width on the detail column — otherwise, widening the chat dock
    // would push this column past the window and slide the dock off the right
    // edge. At normal widths everything fits and nothing scrolls.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if tab == .summary {
                    // Only where a line cannot be corrected in place. With a
                    // typed recap the rendered text is editable itself, and a
                    // second way in — the raw markdown — would write `summary`
                    // while leaving `recap_json` saying the old thing.
                    if meeting.recap?.isEmpty != false {
                        editButton
                        SubToolbarDivider()
                    }
                    copyButton(isEnabled: !isGenerating, action: copySummary)
                    SubToolbarDivider()
                    // The public link, not the audience. Who inside the
                    // organization can open this is stated by the header's
                    // access chip and changed from there — a second control
                    // saying "Shared with Nod" four lines below one already
                    // saying it is the same fact twice, and the row of verbs is
                    // the wrong place for a state.
                    shareButton
                } else {
                    copyButton(isEnabled: transcript.loadedRecords?.isEmpty == false, action: copyTranscript)
                }
                SubToolbarDivider()
                exportButton
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var editButton: some View {
        Button { isEditingSummary.toggle() } label: {
            SubToolbarLabel(
                icon: isEditingSummary ? "nc-check" : "nc-pen-writing",
                text: isEditingSummary ? "Done" : "Edit"
            )
        }
        .buttonStyle(.plain)
        .disabled(isFinalizing)
        .opacity(isFinalizing ? 0.4 : 1)
        .linkCursor()
    }

    private func copyButton(isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SubToolbarLabel(
                icon: copyFlash ? "nc-check" : "nc-files-2",
                text: copyFlash ? "Copied" : "Copy"
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .linkCursor()
    }

    private var shareButton: some View {
        Button(action: shareLink) {
            SubToolbarLabel(icon: shareIcon, text: shareLabel)
        }
        .buttonStyle(.plain)
        .disabled(isFinalizing || shareState == .sharing)
        .opacity(isFinalizing ? 0.4 : 1)
        .linkCursor()
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

    // MARK: - Actions

    private func copySummary() {
        let title = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let date = Self.dateFormatter.string(from: meeting.startedAt)
        copyAndFlash(title.isEmpty
            ? "\(date)\n\n\(meeting.summary)"
            : "\(title)\n\(date)\n\n\(meeting.summary)")
    }

    private func copyTranscript() {
        guard let records = transcript.loadedRecords, !records.isEmpty else { return }
        copyAndFlash(
            transcriptPlainText(
                records,
                names: meeting.speakerNames,
                host: hostName,
                selfSpeaker: meeting.selfSpeaker
            )
        )
    }

    private func copyAndFlash(_ text: String) {
        NSPasteboard.copyText(text)
        analytics.recordMeetingInteraction(
            .contentCopied,
            contentType: tab == .summary ? .summary : .transcript,
            meeting: meeting,
            outcome: .success
        )
        Task { await flashConfirmation(set: { copyFlash = true }, reset: { copyFlash = false }, for: 1.5) }
    }

    /// Mints (or reuses) a public share link for this meeting and drops it on
    /// the clipboard. The link is summary-only and revocable — sharing is an
    /// explicit action, never automatic. Errors flip the button to a transient
    /// "Try again" state rather than throwing a modal.
    private func shareLink() {
        guard !isFinalizing, shareState != .sharing else { return }
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
    /// frontmatter + summary + transcript). Reuses the already-loaded transcript
    /// when present, otherwise fetches it. A data-ownership feature: the user
    /// picks where the file lands via the standard save panel.
    private func exportMarkdown() {
        guard !isFinalizing, !isGenerating, exportState != .exporting else { return }
        exportState = .exporting
        Task {
            let records: [TranscriptRecord] = if let loaded = transcript.loadedRecords {
                loaded
            } else {
                await (try? meetingStore.fetchTranscript(meetingID: meeting.id)) ?? []
            }
            let markdown = MeetingMarkdownExport.render(
                meeting: meeting,
                transcript: records,
                tags: labelStore.labels(for: meeting.id).map(\.name),
                actionItems: actionItemStore.items(forMeeting: meeting.id),
                host: hostName
            )

            let panel = NSSavePanel()
            panel.nameFieldStringValue = MeetingMarkdownExport.fileName(for: meeting)
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
                    meeting: meeting,
                    outcome: .success
                )
                await flashConfirmation(set: { exportState = .saved }, reset: { exportState = .idle }, for: 1.8)
            } catch {
                Log.ui.error("markdown export failed: \(error.localizedDescription)")
                await flashConfirmation(set: { exportState = .failed }, reset: { exportState = .idle }, for: 2.5)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The chrome of the sub-toolbar above a meeting's body: a read-only fact, a
/// tappable label, and the hairline between them.
struct SubToolbarLabel: View {
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

struct SubToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: 0.5, height: 14)
    }
}
