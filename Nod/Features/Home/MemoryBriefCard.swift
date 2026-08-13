import SwiftUI

/// The brief under the chat's openers: what is in memory right now, and the
/// context the user was last in. Without it the home screen is a title, four
/// chips and a lot of nothing — it reads as a product that doesn't yet know
/// what to put here.
struct MemoryBriefCard: View {
    let onOpenAttention: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService

    @State private var brief: MemoryBrief?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canUseActionItems: Bool {
        entitlements.mayUse(.actionItems)
    }

    var body: some View {
        content
            .animation(.standard(reduceMotion: reduceMotion), value: brief)
            // Paint from whatever is already loaded first, then again once the
            // refresh lands — the stores are usually warm by the time this
            // mounts, and waiting on the round trip made the card arrive late
            // for no reason.
            .task {
                rebuild()
                await actionItemStore.refresh()
                rebuild()
            }
            // Follows task edits too: ticking one off has to change the number.
            .onChange(of: actionItemStore.revision) { _ in rebuild() }
            // The whole list, not `digestKey`: that key is count + newest id, and a
            // recap landing on a session already in the list changes neither — while
            // it is exactly what the decision count is read from.
            .onChange(of: meetingStore.meetings) { _ in rebuild() }
    }

    /// The empty branch is a real, zero-height view rather than nothing.
    ///
    /// The modifiers above are what fill `brief`, and SwiftUI does not run
    /// `.task` on a branch that renders no content inside a `LazyVStack` — so
    /// with `Group { if let brief … }` the card could never appear: the work
    /// that would have set the state hung off a view that only existed once the
    /// state was set. It looked fine on a cold launch, where a parent redraw
    /// happened to realise it, and never came back after that.
    @ViewBuilder private var content: some View {
        if let brief, !brief.isEmpty {
            card(brief)
                .transition(.answerArrival(reduceMotion: reduceMotion))
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func card(_ brief: MemoryBrief) -> some View {
        Button(action: onOpenAttention) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("In your memory")
                Text(brief.summary)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let context = brief.mostActiveContext {
                    HStack(spacing: 5) {
                        Image("nc-refresh-2")
                            .icon(9.5)
                        Text("Last in \(context)")
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("See what needs your attention")
    }

    private func rebuild() {
        let open = canUseActionItems ? actionItemStore.openItems.count : 0
        brief = MemoryBrief.build(meetings: meetingStore.meetings, openCommitments: open)
    }
}
