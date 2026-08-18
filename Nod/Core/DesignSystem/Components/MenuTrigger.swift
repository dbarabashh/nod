import SwiftUI

/// The label for a `Menu` that has to look like a control.
///
/// A bare `Text` under `.plainMenuChrome()` is invisible as a control: muted
/// type with no edge reads as a caption, and "Add someone" sitting under a team
/// roster read as the empty state rather than the way out of it.
struct MenuTrigger: View {
    let title: String
    var icon: String?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
        return HStack(spacing: 5) {
            if let icon {
                Image(icon)
                    .icon(9)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Image("nc-chevron-down")
                .icon(8)
        }
        .foregroundStyle(isHovering ? Theme.Palette.ink : Theme.Palette.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .hoverSurface(isHovering, in: shape, reduceMotion: reduceMotion)
        .contentShape(shape)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    HStack(spacing: 12) {
        MenuTrigger(title: "Admin")
        MenuTrigger(title: "Manage")
        MenuTrigger(title: "Add someone", icon: "nc-plus")
    }
    .padding()
    .background(Theme.Palette.bg)
}
