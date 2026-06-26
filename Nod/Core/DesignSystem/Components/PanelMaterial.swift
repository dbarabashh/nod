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

    var body: some View {
        ZStack {
            PanelEffect(material: material)
            DesignTokens.Surface.level0.opacity(0.32)
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

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
