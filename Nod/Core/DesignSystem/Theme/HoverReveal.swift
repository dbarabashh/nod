import SwiftUI

extension Animation {
    /// The app's standard reveal-on-hover timing. A gentle spring gives the
    /// natural settle macOS uses for row actions; Reduce Motion collapses it to
    /// a quick crossfade with no spring overshoot.
    static func hoverReveal(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 0.68)
    }

    /// Default spring for UI state changes — a selection moving, a control
    /// swapping, a value settling. Critically damped (no overshoot) so it reads
    /// as quick and calm, per Apple's fluid-interface guidance (response ~0.35,
    /// damping 1.0). Prefer this over ad-hoc `.easeInOut`/`.easeOut` durations:
    /// a spring animates from the presentation value, so it stays smooth when
    /// interrupted or re-targeted mid-flight. Reduce Motion → short crossfade.
    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.35, dampingFraction: 1.0)
    }

    /// Spring for motion that carried momentum into the animation — a sheet that
    /// flies in, a card the user flicked, anything with a sense of arrival. A
    /// little under-damped so it overshoots and settles (damping ~0.8). Use only
    /// when the gesture itself was physical; on a plain fade/appear it feels
    /// wrong. Reduce Motion drops the bounce for a short crossfade.
    static func momentum(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.8)
    }
}

extension AnyTransition {
    /// Slide in/out from an edge (paired with a fade), but collapse to a plain
    /// crossfade under Reduce Motion. The `.standard`/`.momentum` springs only
    /// change an animation's *curve* — they can't stop a `.move` transition from
    /// translating, which is the exact vestibular motion Reduce Motion opts out
    /// of. Use this at every `.move(edge:)` call site so the opt-out is real.
    static func edgeSlide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }
}

extension View {
    /// Fade + subtle scale-in that keeps the view's layout slot and disables
    /// hits while hidden. Sets no animation itself — pair with `.hoverReveal`
    /// on an ancestor keyed to the same state.
    func revealOnHover(_ isVisible: Bool, reduceMotion: Bool, anchor: UnitPoint = .center) -> some View {
        opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.82), anchor: anchor)
            .allowsHitTesting(isVisible)
    }

    /// Shows the macOS link pointer (the pointing hand) over a clickable custom
    /// control. No-op before macOS 15, where `pointerStyle` is unavailable.
    @ViewBuilder func linkCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}
