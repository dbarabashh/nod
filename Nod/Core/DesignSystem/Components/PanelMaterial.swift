import AppKit
import SwiftUI

/// Behind-window blur for the floating panel's surfaces. SwiftUI's
/// `.ultraThinMaterial` uses `withinWindow` blending by default, which
/// renders as solid black on a `.nonactivatingPanel` that has no own
/// content for it to sample. `.behindWindow` samples the desktop / app
/// underneath the panel, which is what users actually see through it.
///
/// Because `.behindWindow` samples the desktop, the bare material goes pale
/// over a light wallpaper / light app window — and the white-on-dark content
/// drawn on top loses contrast. A dark scrim pins every surface to a
/// consistent dark glass regardless of what's behind the panel.
struct PanelMaterial: View {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Rounds the blur itself. SwiftUI's `clipShape` doesn't clip an
    /// AppKit-backed view, so a rounded card drawn on this material still shows
    /// the effect view's square corners — and, on a window with padding around
    /// the card, a grey rectangle spilling out behind it.
    var cornerRadius: CGFloat = 0
    /// How hard the dark scrim pins the blur. The default is tuned for the
    /// panel's small pills; a large surface needs more, because the bigger the
    /// area the more desktop bleeds through it and the less contrast the
    /// white-on-dark content keeps.
    var scrim: Double = 0.32

    /// The panel's small floating pills — the default weight.
    static func pill(_ material: NSVisualEffectView.Material = .hudWindow) -> PanelMaterial {
        PanelMaterial(material: material)
    }

    /// A whole-window surface. Heavier scrim on purpose: the larger the area,
    /// the more desktop bleeds through and the less contrast white-on-dark
    /// content keeps.
    static func card(cornerRadius: CGFloat, material: NSVisualEffectView.Material = .hudWindow) -> PanelMaterial {
        PanelMaterial(material: material, cornerRadius: cornerRadius, scrim: 0.62)
    }

    var body: some View {
        ZStack {
            PanelEffect(material: material, cornerRadius: cornerRadius)
            DesignTokens.Surface.level0.opacity(scrim)
        }
    }
}

extension View {
    /// Glassy white pill matching the marketing site's primary CTA. Every
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

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        apply(cornerRadius, to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        apply(cornerRadius, to: nsView)
    }

    private func apply(_ radius: CGFloat, to view: NSVisualEffectView) {
        guard radius > 0 else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
