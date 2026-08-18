import SwiftUI

/// What a turn did before it answered, collapsed by default.
///
/// The shape borrowed from a reasoning accordion — a disclosure whose header
/// counts the work and whose body is a timeline — but the content is different
/// on purpose. We don't ask models for their reasoning, so this shows actions:
/// which product was reached into, with what, and what came back. Reasoning is
/// a claim; this is a record.
///
/// Nothing here names a product. A step carries its own `IntegrationProvider`,
/// so the day Notion is added its steps render with the Notion mark and read
/// "Searched Notion" without this file changing.
struct ChatTurnTrace: View {
    let steps: [ChatTurnStep]

    @State private var isExpanded = false

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                if isExpanded {
                    timeline
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.standard(reduceMotion: reduceMotion), value: isExpanded)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var header: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Image("nc-chevron-down")
                    .icon(9)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    /// Counts the work rather than naming it: the detail is one click away, and
    /// a header that listed every step would be the timeline twice.
    private var summary: String {
        let failed = steps.filter { if case .failed = $0.outcome { true } else { false } }.count
        let declined = steps.filter { $0.outcome == .declined }.count
        let notes = [
            failed > 0 ? "\(failed) failed" : nil,
            declined > 0 ? "\(declined) declined" : nil
        ].compactMap { $0 }
        return ([ChatThinking.counted(steps.count, "step")] + notes).joined(separator: ", ")
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    rail(isLast: index == steps.count - 1)
                    row(step)
                        .padding(.bottom, index == steps.count - 1 ? 0 : 8)
                }
            }
        }
        .padding(.leading, 2)
    }

    /// The dot and the thread between steps. The last one fades out instead of
    /// stopping flat, so the list reads as finished rather than cut off.
    private func rail(isLast: Bool) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Theme.Palette.muted.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            Rectangle()
                .fill(isLast
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Theme.Palette.border, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    : AnyShapeStyle(Theme.Palette.border))
                .frame(width: 1.5)
                .clipShape(Capsule())
        }
        .frame(width: 5)
    }

    private func row(_ step: ChatTurnStep) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                ProviderMark(provider: step.provider, size: 11)
                Text(step.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.8))
                outcomeMark(step.outcome)
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func outcomeMark(_ outcome: ChatTurnStep.Outcome) -> some View {
        switch outcome {
        case .ran:
            Image("nc-check")
                .icon(9)
                .foregroundStyle(Theme.Palette.success)
        case .declined:
            Text("declined")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
        case let .failed(message):
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)
                .lineLimit(1)
        }
    }
}
