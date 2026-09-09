import SwiftUI

extension Binding {
    /// A `Bool` for `isPresented:`/`confirmationDialog`/`.alert`, driven by
    /// whichever optional holds the thing being confirmed or edited — `true`
    /// while it's non-nil, and dismissal (Cancel, swipe, tap outside) clears
    /// it back to `nil` rather than just flipping a flag the optional then
    /// has to be cleared separately.
    static func isPresented(by optional: Binding<(some Any)?>) -> Binding<Bool> where Value == Bool {
        Binding<Bool>(
            get: { optional.wrappedValue != nil },
            set: { if !$0 { optional.wrappedValue = nil } }
        )
    }
}

extension View {
    /// Closes a popover when whatever it is anchored to moves.
    ///
    /// A macOS popover keeps its screen position, so scrolling the page behind
    /// one leaves it floating over unrelated content, still pointing at a chip
    /// that is no longer there. AppKit's own menus dismiss on scroll for the
    /// same reason.
    ///
    /// Watches the anchor rather than the scroll view: there is no reference to
    /// the enclosing `NSScrollView` from here, and a live-scroll notification
    /// cannot tell the page's scrolling from the popover's own list scrolling.
    /// The anchor only moves for the first.
    func dismissWhenMoved(_ isPresented: Binding<Bool>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.frame(in: .global).origin.y) { _ in
                        if isPresented.wrappedValue { isPresented.wrappedValue = false }
                    }
            }
        )
    }
}
