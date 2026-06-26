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
