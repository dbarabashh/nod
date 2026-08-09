import SwiftUI

/// The deadline tag under an action item, shared by the meeting's checklist and
/// the cross-meeting one. Owns the urgency→colour mapping and the tooltip as
/// well as the shape: when the two screens each rendered their own, the tooltip
/// content had already drifted between them.
extension ActionItemDeadline.Urgency {
    /// A missed date is the only one that earns alarm colour; a phrase we can't
    /// date reads as plain metadata so an old "end of week" doesn't keep
    /// shouting. Lives here rather than in the pill because the attention
    /// column renders the same urgency as bare text — and its own copy of this
    /// map had already drifted on `.upcoming`.
    var tint: Color {
        switch self {
        case .overdue: Theme.Palette.danger
        case .imminent: Theme.Palette.warning
        case .upcoming: Theme.Palette.brand
        case .vague: Theme.Palette.muted
        }
    }
}

struct DeadlinePill: View {
    let display: ActionItemDeadline.Display
    let spokenAt: Date
    /// Named only where the list spans meetings; inside one meeting's checklist
    /// the source is never in question.
    var meetingTitle: String?
    var compact = false
    /// A ticked task is not overdue. Without this the row keeps its alarm colour
    /// after the user has already dealt with it — and every list here keeps
    /// showing done items rather than removing them.
    var done = false

    private var tint: Color {
        done ? Theme.Palette.muted : display.urgency.tint
    }

    var body: some View {
        Text(display.text)
            .font(.system(size: compact ? 10.5 : 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
            .hoverTooltip(
                display.headline,
                detail: ActionItemDeadline.sourceLine(
                    quote: display.quote,
                    spokenAt: spokenAt,
                    meetingTitle: meetingTitle
                ),
                icon: "nc-calendar"
            )
    }
}
