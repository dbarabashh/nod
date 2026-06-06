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
