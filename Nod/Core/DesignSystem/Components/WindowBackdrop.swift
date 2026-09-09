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

/// How high a card floats over the window: a `modal` sits over a scrim in the
/// middle of the window; a `toast` sits in a corner over live content and
/// casts less.
enum PromptCardElevation {
    case modal
    case toast

    var shadow: DesignTokens.Shadow.Drop {
        switch self {
        case .modal: (DesignTokens.Shadow.ink(light: 0.16, dark: 0.35), 24, 0, 10)
        case .toast: (DesignTokens.Shadow.ink(light: 0.10, dark: 0.20), 16, 0, 6)
        }
    }
}

/// A card asking an existing account something once, over the main window.
///
/// The window's own ground, not a palette colour: `surfaceCard()` let the
/// content read through, and a flat fill (`bgSoft`) reads navy against the
/// window's neutral material. `WindowBackdrop` blends behind the WINDOW, so
/// sibling views stay hidden while the card matches its surroundings.
extension View {
    func promptCard(width: CGFloat, padding: CGFloat = 22, elevation: PromptCardElevation = .modal) -> some View {
        let shadow = elevation.shadow
        return self
            .padding(padding)
            .frame(width: width)
            .background(WindowBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                    .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
            )
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

#Preview {
    ZStack {
        WindowBackdrop()
        Theme.Palette.scrim
        VStack(spacing: 24) {
            Text("Asked once, over the window")
                .foregroundStyle(Theme.Palette.ink)
                .promptCard(width: 420)
            Text("A corner toast")
                .foregroundStyle(Theme.Palette.ink)
                .promptCard(width: 300, padding: 16, elevation: .toast)
        }
    }
    .frame(width: 600, height: 400)
}
