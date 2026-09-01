import AppKit
import SwiftUI

/// Behind-window blur for the floating panel's surfaces. SwiftUI's
/// `.ultraThinMaterial` uses `withinWindow` blending by default, which
/// renders as solid black on a `.nonactivatingPanel` that has no own
/// content for it to sample. `.behindWindow` samples the desktop / app
/// underneath the panel, which is what users actually see through it.
///
/// Because `.behindWindow` samples the desktop, the bare material takes the
/// wallpaper's brightness with it — and the content drawn on top loses
/// contrast. A scrim in the theme's base colour pins every surface to a
/// consistent glass regardless of what's behind the panel.
///
/// Turned off — by the user in Settings, or by macOS's own Reduce
/// transparency — every surface becomes a flat elevated fill instead.
struct PanelMaterial: View {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Rounds the blur itself. SwiftUI's `clipShape` doesn't clip an
    /// AppKit-backed view, so a rounded card drawn on this material still shows
    /// the effect view's square corners — and, on a window with padding around
    /// the card, a grey rectangle spilling out behind it.
    var cornerRadius: CGFloat = 0
    /// How hard the scrim pins the blur. The default is tuned for the
    /// panel's small pills; a large surface needs more, because the bigger the
    /// area the more desktop bleeds through it and the less contrast the
    /// content keeps.
    var scrim: Double = 0.32

    /// A whole-window surface. Heavier scrim on purpose: the larger the area,
    /// the more desktop bleeds through and the less contrast the content
    /// keeps.
    static func card(cornerRadius: CGFloat, material: NSVisualEffectView.Material = .hudWindow) -> PanelMaterial {
        PanelMaterial(material: material, cornerRadius: cornerRadius, scrim: 0.62)
    }

    var body: some View {
        BackdropSurface {
            PanelEffect(material: material, cornerRadius: cornerRadius)
                .overlay(DesignTokens.Surface.level0.opacity(scrim))
        } flat: {
            // The scrim exists to claw back contrast the blur gives away; with
            // no blur underneath there is nothing to claw back, so the surface
            // is the plain elevated colour rather than a wash of it.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.Palette.bgSoft)
        }
    }
}

/// The single gate every translucent surface passes through: the user's
/// Appearance switch, and macOS's own Reduce transparency, which overrides it.
/// One place so a window and the panel floating over it can never disagree
/// about whether Nod is blurring today.
struct BackdropSurface<Blurred: View, Flat: View>: View {
    @ViewBuilder var blurred: () -> Blurred
    @ViewBuilder var flat: () -> Flat

    @AppStorage(AppearanceDefaults.transparencyKey)
    private var isTransparencyEnabled = AppearanceDefaults.isTransparentByDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if isTransparencyEnabled, !reduceTransparency {
            blurred()
        } else {
            flat()
        }
    }
}

extension Shape {
    /// The in-window frosted fill — the `Material` family, not the panel's
    /// behind-window blur. Routed through the same gate so "Transparent
    /// background: off" reaches the tooltips, toasts, and fields that float
    /// inside a window as well as the windows themselves.
    func glassFill() -> some View {
        BackdropSurface {
            fill(.ultraThinMaterial)
        } flat: {
            fill(Theme.Palette.bgSoft)
        }
    }
}

extension View {
    /// Glassy pill matching the marketing site's primary CTA — white on the
    /// dark theme, near-black on the light one. Every
    /// value — fill, text colour, border, shadow — comes from the single
    /// `Theme.GlassButton` source, so the whole app's primary buttons restyle
    /// from one place. Sets a default dark foreground for the label (an inner
    /// view can still override, e.g. an accent icon). Pass the button's own
    /// shape so fill, clip, and border stay in sync.
    func glassButtonSurface(_ shape: some InsettableShape) -> some View {
        foregroundColor(Theme.GlassButton.text)
            .background(
                shape
                    .fill(Theme.GlassButton.fill)
                    .clipShape(shape)
            )
            .overlay(shape.strokeBorder(Theme.GlassButton.border, lineWidth: Theme.GlassButton.borderWidth))
            .shadow(
                color: Theme.GlassButton.shadow.color,
                radius: Theme.GlassButton.shadow.radius,
                x: Theme.GlassButton.shadow.x,
                y: Theme.GlassButton.shadow.y
            )
    }
}

struct PanelEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0

    /// Pinned rather than inherited: an `NSVisualEffectView` resolves against
    /// its window, while the flat fill that replaces it resolves against the
    /// SwiftUI scheme. Under a subtree that forces one (onboarding's light
    /// cards) the two disagreed, so the transparency switch changed the card's
    /// theme instead of only its blur.
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        apply(cornerRadius, to: view)
    }

    private func apply(_ radius: CGFloat, to view: NSVisualEffectView) {
        guard radius > 0 else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
