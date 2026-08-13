import SwiftUI

/// The way into what needs the user — a count, not a column.
///
/// The attention list used to be a third column standing open on every screen,
/// which made the product read as an inbox with a chat attached. What it
/// actually is, is one number most of the time: nothing here is urgent enough to
/// hold a fifth of the window hostage while someone is asking a question about
/// last week.
///
/// Takes its stores from the environment rather than being handed a count, for
/// the same reason `AmbientContextSidebarRow` does: ticking a task off would
/// otherwise invalidate the whole sidebar to redraw one row.
struct AttentionSidebarRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @State private var count = 0

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image("nc-sidebar-right")
                    .icon(12.5)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
                    .opacity(isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See what needs your attention")
        .onChange(of: actionItemStore.revision) { _ in recount() }
        .onChange(of: meetingStore.digestKey) { _ in recount() }
        .onAppear(perform: recount)
    }

    /// "7 things need attention" — and when there are none, the row says so
    /// rather than disappearing. A control that comes and goes is one the user
    /// has to look for; a zero is information.
    private var label: String {
        switch count {
        case 0: "Nothing needs attention"
        case 1: "1 thing needs attention"
        default: "\(count) things need attention"
        }
    }

    /// The same two piles the column itself shows, counted the same way — a
    /// number here that disagreed with the list behind it would make both
    /// worthless.
    private func recount() {
        let actions = entitlements.mayUse(.actionItems) ? actionItemStore.openItems.count : 0
        count = actions + TodayDigest.openPointCount(meetings: meetingStore.meetings)
    }
}
