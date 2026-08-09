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
        Group {
            if let brief, !brief.isEmpty {
                card(brief)
                    .transition(.answerArrival(reduceMotion: reduceMotion))
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: brief)
        .task { await actionItemStore.refresh() }
        // Follows task edits too: ticking one off has to change the number.
        .onChange(of: actionItemStore.revision) { _ in rebuild() }
        .onChange(of: meetingStore.digestKey) { _ in rebuild() }
        .onAppear(perform: rebuild)
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
