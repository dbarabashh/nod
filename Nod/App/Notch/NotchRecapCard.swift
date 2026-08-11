import SwiftUI

// MARK: - Recap, right where the meeting just ended

/// The one thing this whole surface has been building toward: the meeting is
/// over, and the recap is right here instead of behind a window the user has
/// to go find. Raised on its own — see `NotchPresentation.recap` — and reads
/// straight off `MeetingStore`, the same source `MeetingDetailView` renders
/// from, so the two never disagree about what happened.
///
/// No "completed automatically" section, no auto-booked follow-up: those
/// exist in the landing-page demo (`DemoSummaryCard`) as the destination once
/// integrations land. This shows only what is real today — the recap and its
/// action items.
struct NotchRecapCard: View {
    let state: RecapState
    let onClose: () -> Void
    let onExpand: (UUID) -> Void
    let onCopy: (SessionKind) -> Void

    private static let maxHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            content(for: state)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("nc-file")
                .icon(12)
                .foregroundStyle(Theme.Palette.brand)
            Text("Meeting summary")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            NotchGlyphButton(icon: "nc-xmark", help: "Dismiss", action: onClose)
        }
    }

    @ViewBuilder
    private func content(for state: RecapState) -> some View {
        switch state {
        case .generating:
            generating
        case let .ready(meeting):
            ready(meeting)
        case let .failed(message):
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No live partial text: streaming it in redrew this card, and the model's
    /// own identity-change churned the fold-through-resting transition, on
    /// every token the summary streamed. Same three-line script
    /// `MeetingDetailView` paces its own placeholder with, so ending the
    /// meeting in the notch and watching it from the detail view read as one
    /// thing happening, not two.
    private var generating: some View {
        ThinkingIndicator(script: [
            "Writing the recap…",
            "Capturing decisions & action items…",
            "Almost there…"
        ])
    }

    private func ready(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(renderRecapMarkdown(meeting.summary))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)

                    if let items = meeting.recap?.actionItems, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ACTION ITEMS")
                                .font(.system(size: 9.5, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(Theme.Palette.muted.opacity(0.9))
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(items, id: \.text) { item in
                                    actionRow(item)
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: Self.maxHeight)

            // Bottom-right rather than beside the dismiss glyph: closing is
            // what you do to the card, these are what you do with the meeting.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                NotchCopyGlyphButton(
                    text: {
                        MeetingMarkdownExport.summaryPayload(
                            meeting: meeting,
                            actions: meeting.recap?.actionItems ?? []
                        )
                    },
                    onCopy: { onCopy(meeting.kind) }
                )
                NotchGlyphButton(icon: "nc-arrow-up-right", help: "Open meeting") { onExpand(meeting.id) }
            }
        }
    }

    private func actionRow(_ item: MeetingRecap.Action) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.Palette.muted.opacity(0.7))
                .frame(width: 3, height: 3)
                .padding(.top, 5.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline = item.deadline {
                    Text(deadline)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
