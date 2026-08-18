import SwiftUI

/// The inline search row: a magnifier, a field, and a clear button once there
/// is something to clear.
///
/// Written out at each list that needed one, the copies drifted — different
/// icon sizes, different type sizes, and only some of them offering a way back
/// to the unfiltered list.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image("nc-magnifier")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image("nc-circle-xmark")
                        .icon(12)
                        .foregroundStyle(Theme.Palette.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // The row is as tall as its own text: left free it takes a share of any
        // height it is given, and a field editor draws its line at the top of
        // the box it was handed — so the text climbs away from the magnifier.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
        )
    }
}
