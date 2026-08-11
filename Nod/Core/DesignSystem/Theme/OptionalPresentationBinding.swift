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
