import SwiftUI

/// Press-down feedback for the app's custom pill / icon buttons. Apple's first
/// rule of directness is *respond on pointer-down, not on release* — a control
/// that only reacts on `click` feels dead. This applies a subtle scale the
/// instant the button is pressed and releases it on lift, so every custom
/// button gets the same tactile response from one place.
///
/// Drop-in replacement for `.buttonStyle(.plain)`: it renders the label with no
/// chrome of its own, just the press transform. Reduce Motion keeps the press
/// feedback but flattens it to an opacity dip (non-vestibular) instead of scale.
struct PressableButtonStyle: ButtonStyle {
    /// How far the label scales while pressed. Tuned per-button: large pills sit
    /// around `0.97`; tiny icon discs can go a touch deeper.
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1.0 : (pressed ? scale : 1.0))
            .opacity(reduceMotion && pressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.10), value: pressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Default press feedback — use in place of `.plain` on custom buttons.
    static var pressable: PressableButtonStyle {
        PressableButtonStyle()
    }

    /// Press feedback with a custom scale, e.g. `.pressable(scale: 0.92)` for a
    /// small icon button that wants a deeper press.
    static func pressable(scale: CGFloat) -> PressableButtonStyle {
        PressableButtonStyle(scale: scale)
    }
}
