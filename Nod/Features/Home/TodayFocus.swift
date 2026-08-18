import SwiftUI

/// What is waiting for you, on the screen you open Nod onto.
///
/// This used to be a surface of its own — "Needs your attention" — reachable
/// from a sidebar row, from two of the home's stat tiles, and duplicating the
/// Actions list it linked back out to. Five doors, two of them indistinguishable,
/// and a screen whose only unique content was the unresolved list. The counts
/// live here now, each one leading somewhere different: open actions to the
/// checklist that owns them, unresolved to its own rows, opened in place because
/// there is no other screen that holds them.
struct TodayFocus: View {
    let onOpenActions: () -> Void
    let onOpenMeeting: (UUID) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var unresolved: [TodayDigest.OpenPoint] = []
    @State private var unresolvedCount = 0
    @State private var openActions = 0
    @State private var isShowingUnresolved = false

    private var canUseActionItems: Bool {
        entitlements.mayUse(.actionItems)
    }

    private var isEmpty: Bool {
        openActions == 0 && unresolvedCount == 0
    }

    var body: some View {
        content
            .animation(.standard(reduceMotion: reduceMotion), value: isShowingUnresolved)
            .task {
                rebuild()
                await actionItemStore.refresh()
                rebuild()
            }
            .onChange(of: actionItemStore.revision) { _ in rebuild() }
            .onChange(of: meetingStore.meetings) { _ in rebuild() }
    }

    /// A real zero-height view rather than nothing: the `.task` above is what
    /// fills the counts, and SwiftUI does not run it on a branch that renders no
    /// content — the same trap `MemoryBriefCard` documents.
    @ViewBuilder private var content: some View {
        if isEmpty {
            Color.clear.frame(height: 0)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("For you today")
                VStack(spacing: 0) {
                    if openActions > 0 {
                        row(
                            icon: "nc-check",
                            title: "Open actions",
                            count: openActions,
                            action: onOpenActions
                        )
                    }
                    if unresolvedCount > 0 {
                        if openActions > 0 {
                            Divider().overlay(Theme.Palette.border).padding(.leading, 40)
                        }
                        row(
                            icon: "nc-msgs",
                            title: "Unresolved",
                            count: unresolvedCount,
                            trailing: isShowingUnresolved ? .expanded : .collapsed,
                            action: { isShowingUnresolved.toggle() }
                        )
                        if isShowingUnresolved {
                            unresolvedRows
                        }
                    }
                }
                .surfaceCard()
            }
        }
    }

    /// What the row's trailing edge promises. A `Bool?` said the same thing in
    /// three states with two spellings, and every read of it was a ternary.
    private enum Trailing {
        case navigate
        case expanded
        case collapsed

        var label: String {
            self == .expanded ? "Hide" : "Review"
        }

        var chevron: String {
            switch self {
            case .navigate: "nc-chevron-right"
            case .expanded: "nc-chevron-up"
            case .collapsed: "nc-chevron-down"
            }
        }
    }

    private func row(
        icon: String,
        title: String,
        count: Int,
        trailing: Trailing = .navigate,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(icon)
                    .icon(13)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Palette.surfaceStrong))
                Spacer(minLength: 8)
                Text(trailing.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                Image(trailing.chevron)
                    .icon(9)
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    /// Opened in place. The unresolved list has no screen of its own, and giving
    /// it one would be a fourth door to a place that holds a dozen rows.
    private var unresolvedRows: some View {
        VStack(spacing: 0) {
            ForEach(unresolved) { point in
                Divider().overlay(Theme.Palette.border).padding(.leading, 40)
                Button { onOpenMeeting(point.meeting.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(point.meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 40)
                    .padding(.trailing, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Open this session")
            }
        }
    }

    /// One walk of the recaps, not two: `openPointCount` and `openPoints` scan
    /// the same sections with the same filter, and this ran both on every
    /// change to the meeting list.
    private func rebuild() {
        openActions = canUseActionItems ? actionItemStore.openItems.count : 0
        let points = TodayDigest.openPoints(meetings: meetingStore.meetings, limit: .max)
        unresolvedCount = points.count
        unresolved = Array(points.prefix(6))
    }
}
