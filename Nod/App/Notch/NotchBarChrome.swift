import SwiftUI

/// The parts of the meeting bar that are the same whether you are recording the
/// meeting or listening to somebody else record it.
///
/// These lived in `NotchMeetingBar.swift` as private helpers until a second bar
/// needed them, at which point copying them across looked cheap and was not: the
/// two surfaces are the ones least likely to be opened in the same sitting, so a
/// drift between them survives review. Anything here is load-bearing for both.

/// The header's three groups. The spacing is the shape of the bar, and it is
/// stated once so the two sides cannot disagree about it.
struct MeetingBarHeader<Left: View, Center: View, Right: View>: View {
    private let left: Left
    private let center: Center
    private let right: Right

    /// Builders are called here and the results stored, per the house rule: a
    /// stored view-builder closure captures its enclosing view and re-evaluates
    /// whenever any of its properties change.
    init(
        @ViewBuilder left: () -> Left,
        @ViewBuilder center: () -> Center,
        @ViewBuilder right: () -> Right
    ) {
        self.left = left()
        self.center = center()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 8) {
            left
            Spacer(minLength: 4)
            center
            Spacer(minLength: 4)
            right
        }
    }
}

/// One line of quiet status under the header — "Alina is recording this too",
/// "two others are listening", "recording stopped".
///
/// A line rather than a card, deliberately: there is nothing to decide, and a
/// prompt would interrupt somebody mid-meeting to tell them something they do
/// not have to act on.
struct MeetingBarStatusLine: View {
    let icon: String
    let text: String
    var tint: Color = Theme.Palette.muted

    var body: some View {
        HStack(spacing: 6) {
            Image(icon)
                .icon(11)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

/// The word beside the clock when something deviates from "this is simply
/// running" — "Thinking…", "Paused".
///
/// Shared because the Ask box now outlives the panel it was typed into: with
/// the box folded away this caption is the only thing on either bar that can
/// say an answer is still coming, and a listener asking a question deserves
/// that as much as the host does.
struct MeetingBarCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Whatever is expanded below the header, for either bar.
///
/// The findings are a parameter rather than a source this view reaches for,
/// which is the whole reason one view serves both: the host's come from their
/// own live pass, the listener's arrive through `meeting_live_findings`, and by
/// the time they get here they are the same `[LiveFinding]`.
struct MeetingBarExpansion: View {
    let panel: MeetingBarPanel
    let findings: [LiveFinding]
    let onSubmit: (String) -> Void
    let onSummarize: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        switch panel.expansion {
        case .passive:
            EmptyView()
        case .notes:
            MeetingNotesPanel(findings: findings)
        case .ask:
            MeetingAskPanel(
                phase: panel.ask,
                approval: panel.approval,
                onSubmit: onSubmit,
                onSummarize: onSummarize,
                onApprove: onApprove,
                onDeny: onDeny
            )
        }
    }
}

/// A block of generated prose sitting inside the bar — a catch-up, a summary.
struct MeetingBarProse: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
    }
}
