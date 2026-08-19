import SwiftUI

/// The Summary tab's body: the recap being written, the recap being read, the
/// recap being edited, or the offer to build one that was never made.
struct MeetingSummaryTab: View {
    let meeting: Meeting
    @Binding var summary: String
    /// The typed recap behind the rendered text, and the correction handed
    /// back. Read-only here on purpose: the summary and the recap are one fact
    /// in two columns, and a view that can write either one separately is a
    /// view that can leave them disagreeing.
    let recap: MeetingRecap?
    let onCorrect: (MeetingRecap) -> Void
    let isGenerating: Bool
    let isEditing: Bool
    let isFinalizing: Bool
    /// Finished generating but still queued in the durable outbox.
    let isUnsynced: Bool
    /// Recap markdown streamed in while the summary generates, or nil before
    /// the first section closes.
    let streamingPartial: String?
    let onEdited: () -> Void
    let onRegenerate: () -> Void

    @EnvironmentObject private var summaryRegeneration: SummaryRegeneration

    var body: some View {
        if isGenerating {
            liveRecap(streamingPartial)
        } else if case let .running(partial) = summaryRegeneration.state(for: meeting.id) {
            liveRecap(partial)
        } else if !isEditing, meeting.lacksRecap {
            missingRecap
        } else if isEditing {
            editor
        } else if let recap, !recap.isEmpty {
            EditableRecap(recap: recap, onEdit: onCorrect)
        } else {
            rendered(summary)
        }
    }

    private func rendered(_ markdown: String) -> some View {
        Text(renderRecapMarkdown(markdown))
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Theme.Palette.ink.opacity(0.92))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The rendered partial plus the thinking indicator, so the user watches
    /// sections appear while the model is still writing the rest. Before the
    /// first section closes there is nothing to render, so the indicator stands
    /// alone.
    @ViewBuilder
    private func liveRecap(_ partial: String?) -> some View {
        if let partial {
            VStack(alignment: .leading, spacing: 16) {
                rendered(partial)
                ThinkingIndicator(script: [
                    "Writing the recap…",
                    "Capturing decisions & action items…",
                    "Almost there…"
                ])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Same bouncing-dots indicator as the in-call chat — the label walks
            // a few stages and holds on the last, so the wait reads as live
            // activity instead of a spinner that promises a fixed "few seconds".
            ThinkingIndicator(script: [
                "Generating summary…",
                "Pulling out key points…",
                "Capturing decisions & action items…",
                "Almost there…"
            ])
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
    }

    private var editor: some View {
        TextEditor(text: $summary)
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
            .onChange(of: summary) { _ in onEdited() }
    }

    /// Shown when the meeting kept its transcript but never got a recap — the
    /// recap is the only thing missing, so the offer is to rebuild it.
    private var missingRecap: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.summary)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRegenerate) {
                SubToolbarLabel(icon: "nc-refresh-2", text: "Generate summary")
            }
            .buttonStyle(.plain)
            // A meeting still queued in the outbox would have the regenerated
            // recap overwritten by the next drain — the WAL copy still holds the
            // note, and it wins over the cache until the push lands.
            .disabled(isFinalizing || isUnsynced)
            .opacity(isFinalizing || isUnsynced ? 0.4 : 1)
            .help(isUnsynced
                ? "Available once the meeting finishes syncing"
                : "Rebuild the summary from the saved transcript")
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
}
