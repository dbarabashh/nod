import SwiftUI

extension Image {
    /// Nucleo icons are plain vector assets with no intrinsic point size, unlike
    /// SF Symbols whose glyph scales with `.font`. Every icon needs an explicit
    /// frame instead.
    func icon(_ size: CGFloat) -> some View {
        resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// `Label(_:image:)` can't size its icon — the image renders at its native
/// size with no way to scale it. Use this wherever a menu row or inline label
/// pairs an nc- icon with text.
struct IconLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 11

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(icon).icon(size)
        }
    }
}
