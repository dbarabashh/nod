import SwiftUI

/// The round check control on an action item, shared by the meeting's checklist,
/// the cross-meeting list, and Today so a task reads the same wherever it's
/// ticked off.
struct ActionCheckbox: View {
    let done: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(done ? Theme.Palette.brand : Color.clear)
                .overlay(Circle().stroke(done ? Theme.Palette.brand : Theme.Palette.borderStrong, lineWidth: 1.5))
                .frame(width: 18, height: 18)
            if done {
                Image("nc-check")
                    .icon(9.5)
                    .foregroundStyle(Theme.Palette.bg)
            }
        }
        // The circle has no text baseline, so under `.firstTextBaseline` the HStack
        // would hang it from its bottom edge and float it above the line. Report
        // its center (nudged to the cap height) as the baseline so it sits centered
        // on the first line of text.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .contentShape(Rectangle())
    }
}
