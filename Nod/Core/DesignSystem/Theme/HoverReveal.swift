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

    /// A finished answer taking the place of the thinking indicator.
    ///
    /// It rises a few points as it fades in rather than simply appearing: a
    /// block of text that materialises out of nothing reads as a glitch, while
    /// a short move in the direction the conversation grows reads as arrival.
    /// Kept small — this is a frequent transition, and anything larger would
    /// start costing reading time. Reduce Motion keeps the fade, drops the
    /// movement.
    static func answerArrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: 6))
    }
}

extension View {
    /// Fade + subtle scale-in that keeps the view's layout slot and disables
    /// hits while hidden. Sets no animation itself — pair with `.hoverReveal`
    /// on an ancestor keyed to the same state.
    ///
    /// `scale` is the size it grows from. The 0.82 default was tuned on small
    /// icon buttons, where the zoom reads as the control arriving; on anything
    /// wider — a labelled pill — the same factor travels far enough to read as
    /// a pop, so those callers pass a gentler value.
    func revealOnHover(
        _ isVisible: Bool,
        reduceMotion: Bool,
        anchor: UnitPoint = .center,
        scale: CGFloat = 0.82
    ) -> some View {
        opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : scale), anchor: anchor)
            .allowsHitTesting(isVisible)
    }

    /// The row-under-the-pointer highlight: one containing shape that fades in
    /// on hover, with the timing and the Reduce Motion collapse already right.
    /// Every list that re-rolled this drifted on the fill, so adjacent panes
    /// highlighted at different strengths.
    ///
    /// `fill` is the one thing a caller legitimately changes: the default is
    /// tuned for a row on the window's own background, and a row already
    /// sitting inside a `surfaceCard` needs the lighter step or the two fills
    /// stack into a slab.
    func hoverHighlight(
        _ isHovering: Bool,
        cornerRadius: CGFloat = 8,
        reduceMotion: Bool,
        inset: CGSize = .zero,
        fill: Color = Theme.Palette.surfaceStrong
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
                .opacity(isHovering ? 1 : 0)
                .padding(.horizontal, inset.width)
                .padding(.vertical, inset.height)
                .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHovering)
        )
    }

    /// A small control that carries its own surface at rest — filled, hairline
    /// bordered, brightening on hover. `hoverHighlight` is the version for rows
    /// inside a list, which show nothing until the pointer arrives; this is for
    /// a button that has to be findable before anyone hovers it.
    func hoverSurface(_ isHovering: Bool, in shape: some InsettableShape, reduceMotion: Bool) -> some View {
        background(
            shape
                .fill(isHovering ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
                .overlay(shape.stroke(Theme.Palette.border, lineWidth: 0.5))
                .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHovering)
        )
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
