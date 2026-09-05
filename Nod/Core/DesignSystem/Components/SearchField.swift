import SwiftUI

/// The inline search row: a magnifier, a field, and a clear button once there
/// is something to clear.
///
/// Written out at each list that needed one, the copies drifted — different
/// icon sizes, different type sizes, and only some of them offering a way back
/// to the unfiltered list.
struct SearchField: View {
    enum Size {
        case standard
        /// A step smaller, for a field inside a sheet's form where the field
        /// it filters for is itself the smaller of the two.
        case compact

        /// The only thing the two sizes differ by. Padding and spacing used to
        /// differ too — 8/7 and 10/9 — which is three decisions describing one.
        var style: Theme.TextStyle {
            self == .standard ? Theme.Typography.ui : Theme.Typography.secondary
        }
    }

    let prompt: String
    @Binding var text: String
    var size: Size = .standard

    var body: some View {
        HStack(spacing: Theme.Space.x2) {
            Image("nc-magnifier")
                .icon(Theme.Control.iconMicro)
                .foregroundStyle(Theme.Palette.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .textStyle(size.style)
                .foregroundStyle(Theme.Palette.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image("nc-circle-xmark")
                        .icon(Theme.Control.iconMicro)
                        .foregroundStyle(Theme.Palette.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Clear")
            }
        }
        .padding(.horizontal, Theme.Space.x3)
        .padding(.vertical, Theme.Space.x2)
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

#Preview {
    VStack(spacing: 12) {
        SearchField(prompt: "Search sessions", text: .constant(""))
        SearchField(prompt: "Search 12 teams", text: .constant("design"), size: .compact)
    }
    .padding(20)
    .frame(width: 320)
    .background(Theme.Palette.bg)
}
