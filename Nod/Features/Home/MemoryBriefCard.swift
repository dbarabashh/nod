import SwiftUI

/// The quiet line under the home's focus block: what was captured, what got
/// settled, and where you were last.
///
/// Nothing here is actionable, and that is the division of labour — Today owns
/// every number that leads somewhere, this owns the ones that are simply true.
/// When both carried counts the home told you about your work twice.
struct MemoryBriefCard: View {
    @EnvironmentObject private var meetingStore: MeetingStore

    @State private var brief: MemoryBrief?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(.standard(reduceMotion: reduceMotion), value: brief)
            // A real zero-height view on the empty branch, not nothing: SwiftUI
            // does not run `.task` on a branch that renders no content, so the
            // work that fills `brief` would hang off a view that only exists
            // once `brief` is set.
            .task { rebuild() }
            .onChange(of: meetingStore.meetings) { _ in rebuild() }
    }

    @ViewBuilder private var content: some View {
        if let line = brief?.contextSummary {
            VStack(alignment: .leading, spacing: 3) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                if let context = brief?.mostActiveContext {
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
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func rebuild() {
        brief = MemoryBrief.build(meetings: meetingStore.meetings)
    }
}
