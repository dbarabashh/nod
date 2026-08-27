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
    /// Whose microphone `me` was, when that is not the person reading.
    ///
    /// `Me` is written from the recording device's point of view. On a meeting
    /// somebody shared, the reader is not that device, and a transcript where
    /// half the lines say "Me" is a transcript about nobody.
    let hostName: String?
    /// Which cluster is the person who recorded this — set only for a room
    /// recording, where the user is one voice among the others.
    var selfSpeaker: Int?
    /// True while the remote speakers are still being clustered. The user's own
    /// mic is a single known voice, so its chip is final the moment it exists.
    let isResolvingRemoteSpeakers: Bool
    /// People a voice can be attributed to. Empty on a personal account, which
    /// does not turn the correction off — it turns it into typing the name,
    /// which is worth just as much to a transcript.
    var people: [Person] = []
    /// Answering "who was that" writes into the recording, so only its owner is
    /// offered it. A reader of a shared meeting sees the chips unchanged.
    var canCorrectSpeakers = false
    var onConfirmSpeaker: (Int, Person?, String?) -> Void = { _, _, _ in }
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
                chip(for: record)
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

    /// The plain chip, or the same chip with the correction menu behind it.
    ///
    /// Only a remote voice that was actually clustered can be corrected: the
    /// microphone line is the person reading, and an unclustered line belongs to
    /// no speaker to attribute.
    ///
    /// Offered with an empty roster on purpose. Somebody outside an organization
    /// has nobody to pick and can still type a name, which is the whole of what
    /// a transcript needs.
    @ViewBuilder
    private func chip(for record: TranscriptRecord) -> some View {
        let isRemote = TranscriptSource(rawValue: record.source) == .them
        let resolving = isResolvingRemoteSpeakers && isRemote
        if canCorrectSpeakers, isRemote, let cluster = record.speaker, cluster > 0 {
            SpeakerCorrectionChip(
                label: label(for: record),
                tint: speakerTint(record),
                isResolving: resolving,
                cluster: cluster,
                people: people,
                isNamed: speakerNames?["\(cluster)"]?.isEmpty == false,
                onConfirm: { onConfirmSpeaker(cluster, $0, $1) }
            )
        } else {
            SpeakerChip(label: label(for: record), tint: speakerTint(record), isResolving: resolving)
        }
    }

    private func label(for record: TranscriptRecord) -> String {
        record.displayLabel(names: speakerNames, host: hostName, selfSpeaker: selfSpeaker)
    }

    /// Mic (`me`) is violet; the remote party (`them`) is cyan. A room line is
    /// whichever of the two it turns out to be — the user's own cluster reads
    /// like their mic, everyone else like the far side.
    private func speakerTint(_ record: TranscriptRecord) -> Color {
        switch TranscriptSource(rawValue: record.source) {
        case .me: Theme.Palette.violet.opacity(0.18)
        case .them: Theme.Palette.cyan.opacity(0.18)
        case .room:
            record.speaker != nil && record.speaker == selfSpeaker
                ? Theme.Palette.violet.opacity(0.18)
                : Theme.Palette.cyan.opacity(0.18)
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
/// apart on speaker naming — `host` included, or a transcript pasted out of
/// somebody else's meeting would attribute half of it to whoever pasted it.
func transcriptPlainText(
    _ records: [TranscriptRecord],
    names: [String: String]?,
    host: String? = nil,
    selfSpeaker: Int? = nil
) -> String {
    records
        .map { record in
            let label = record.displayLabel(names: names, host: host, selfSpeaker: selfSpeaker)
            return "[\(transcriptTimeFormatter.string(from: record.ts))] \(label): \(record.text)"
        }
        .joined(separator: "\n")
}
