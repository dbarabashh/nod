import AppKit
import SwiftUI

extension NSImage {
    /// The asset at an explicit point size, which is the only sizing an
    /// `NSMenu` reads. A SwiftUI frame around a menu row's icon does nothing:
    /// AppKit draws `NSMenuItem.image` at the image's own `size`, so a plain
    /// `Image("nc-…")` lands at whatever its SVG canvas says — 18pt next to
    /// 13pt text, against the 9–11pt the same icon gets everywhere else.
    ///
    /// Copied first: `NSImage(named:)` hands back the shared asset, and
    /// resizing that would resize every other use of the icon.
    static func nodIcon(_ name: String, side: CGFloat) -> NSImage? {
        guard let copy = NSImage(named: name)?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side)
        copy.isTemplate = true
        return copy
    }
}

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
///
/// Carries `size` through a menu too, which a frame cannot: see
/// `NSImage.nodIcon(_:side:)`. Without it a `contextMenu` row drew its icon at
/// the SVG canvas's 18pt while the same glyph sat at 9–11pt in the window
/// behind it.
struct IconLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 11

    var body: some View {
        Label {
            Text(title)
        } icon: {
            sizedIcon
        }
    }

    @ViewBuilder
    private var sizedIcon: some View {
        if let image = NSImage.nodIcon(icon, side: size) {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(icon).icon(size)
        }
    }
}
