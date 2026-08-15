import SwiftUI

/// Where the Transcript tab is in its one-shot fetch from `meeting_transcripts`.
///
/// Owned by `MeetingDetailView` rather than by this view: the toolbar's Copy and
/// Export both read the loaded records, and re-fetching for each would make the
/// same round-trip three times.
enum TranscriptLoadState: Equatable {
    case idle
    case loading
    case loaded([TranscriptRecord])
    case failed(String)

    var loadedRecords: [TranscriptRecord]? {
        if case let .loaded(records) = self { return records }
        return nil
    }
}

/// Read-only transcript for a finished meeting, one utterance per row.
struct MeetingTranscriptTab: View {
    let state: TranscriptLoadState
    /// True until the meeting row and its transcript have finished their first
    /// persistence pass — the fetch waits, so it cannot cache an early empty
    /// result for the meeting that just ended.
    let isFinalizing: Bool
    let speakerNames: [String: String]?
    /// True while the remote speakers are still being clustered. The user's own
    /// mic is a single known voice, so its chip is final the moment it exists.
    let isResolvingRemoteSpeakers: Bool
    let onRetry: () -> Void

    var body: some View {
        if isFinalizing {
            ThinkingIndicator(script: [
                "Preparing transcript…",
                "Saving what was said…",
                "Almost there…"
            ])
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        } else {
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        switch state {
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
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(records) { row($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .failed(message):
            failedState(message)
        }
    }

    private var emptyState: some View {
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
    }

    private func failedState(_ message: String) -> some View {
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
            Button("Retry", action: onRetry)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private func row(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SpeakerChip(
                    label: record.displayLabel(names: speakerNames),
                    tint: speakerTint(record),
                    isResolving: isResolvingRemoteSpeakers
                        && TranscriptSource(rawValue: record.source) == .them
                )
                Text(transcriptTimeFormatter.string(from: record.ts))
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
    private func speakerTint(_ record: TranscriptRecord) -> Color {
        switch TranscriptSource(rawValue: record.source) {
        case .me: Theme.Palette.violet.opacity(0.18)
        case .them: Theme.Palette.cyan.opacity(0.18)
        case nil: Theme.Palette.surface
        }
    }
}

private let transcriptTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
}()

/// The transcript as plain text, one line per utterance: `[HH:MM:SS] Me: …`.
/// Next to the rendering so the copied text and the rows on screen can't drift
/// apart on speaker naming.
func transcriptPlainText(_ records: [TranscriptRecord], names: [String: String]?) -> String {
    records
        .map { "[\(transcriptTimeFormatter.string(from: $0.ts))] \($0.displayLabel(names: names)): \($0.text)" }
        .joined(separator: "\n")
}
