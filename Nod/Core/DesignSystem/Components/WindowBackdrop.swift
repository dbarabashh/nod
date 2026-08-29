import SwiftUI

/// Native macOS window vibrancy, replacing a flat fill: the
/// `.underWindowBackground` material with `.behindWindow` blending, a
/// slightly translucent surface that picks up a hint of what's behind the
/// window — the same frosted-glass family as the floating panel, so every
/// window reads as one product instead of flat slabs bolted onto a glass panel.
struct WindowBackdrop: View {
    var body: some View {
        BackdropSurface {
            PanelEffect(material: .underWindowBackground)
        } flat: {
            Theme.Palette.bg
        }
    }
}
