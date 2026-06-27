import AppKit
import SwiftUI

// MARK: - Header menu glyph

/// Shared chrome for a header icon that opens a menu on the non-activating
/// panel: the `glyph` is drawn under a transparent `Menu` that only catches the
/// click. Putting the glyph inside a borderless `Menu`'s own label drops its
/// circle background across macOS versions, so the two are layered instead.
/// Used by the mic, language, and mode header controls so the chrome and its
/// first-click handling stay identical in one place.
struct HeaderMenuGlyph<Glyph: View, MenuItems: View>: View {
    @ViewBuilder var glyph: () -> Glyph
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        ZStack {
            glyph()
            Menu {
                menu()
            } label: {
                Color.clear
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(width: 22, height: 22)
    }
}

extension View {
    /// The standard 22×22 translucent disc behind a header glyph.
    func headerGlyphCircle() -> some View {
        frame(width: 22, height: 22)
            .background(Circle().fill(Color.white.opacity(0.10)))
    }
}

// MARK: - Icon buttons

/// Small circular icon button shared by the panel's chrome — the
/// collapse chevron in `StatusHeader` and the pause / end / expand
/// controls in `CollapsedCapsule`. Single source of truth so collapse
/// and expand stay visually identical.
struct PanelIconButton: View {
    let systemName: String
    var tint: Color = .white.opacity(0.6)
    var fill: Color = .white.opacity(0.10)
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PanelMenuButton: View {
    var body: some View {
        Menu {
            Button("Settings…") {
                NotificationCenter.default.post(name: .nodOpenSettings, object: nil)
            }
            Divider()
            Button("Hide Panel") {
                NotificationCenter.default.post(name: .nodHidePanel, object: nil)
            }
            Divider()
            Button("Quit Nod") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More — Settings, Hide Panel, Quit Nod")
    }
}

// MARK: - Tooltip

/// A small label that fades in just above a header icon while the pointer is
/// over it — a one-word reminder of what the icon does.
struct PanelTooltip: ViewModifier {
    /// How far the capsule floats above its icon. The panel reserves
    /// `reservedTopSpace` of top inset (see `ContentView`) so the lifted capsule
    /// clears the window's top edge — keep `reservedTopSpace` ≥ `lift` + the
    /// capsule's own height, or tooltips clip again.
    static let lift: CGFloat = 24
    static let reservedTopSpace: CGFloat = 30

    let text: String
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { show = hovering }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nodPanelDidMove)) { _ in
                if show { withAnimation(.easeOut(duration: 0.12)) { show = false } }
            }
            .overlay(alignment: .top) {
                if show {
                    Text(text)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
                        .offset(y: -Self.lift)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func panelTooltip(_ text: String) -> some View {
        modifier(PanelTooltip(text: text))
    }
}

// MARK: - Animation

/// Decelerating ease-out (cubic-bézier 0.22, 1, 0.36, 1 — "easeOutQuint") for a
/// purposeful, settled reveal rather than a flat ease-in-out feel. Reduce Motion
/// collapses it to a quick crossfade with no long deceleration.
extension Animation {
    static func panelReveal(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.34)
    }
}

// MARK: - Level meter

/// Compact 4-bar input meter. Bars light progressively with the live mic
/// peak so a glance confirms audio is flowing. Purely a display — no state,
/// redrawn by its `level` input (~10×/sec from the audio tap).
struct LevelMeter: View {
    let level: Float
    private static let thresholds: [Float] = [0.02, 0.06, 0.14, 0.30]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.thresholds, id: \.self) { threshold in
                Capsule()
                    .fill(Color.white.opacity(level >= threshold ? 0.85 : 0.18))
                    .frame(width: 2.5, height: 9)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .help("Microphone level")
    }
}
