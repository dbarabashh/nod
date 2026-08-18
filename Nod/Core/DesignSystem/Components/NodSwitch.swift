import SwiftUI

extension View {
    /// The app's switch.
    ///
    /// A bare `Toggle(...).nodSwitch()` paints its on state with the
    /// macOS system accent — blue on a default Mac, and off-palette against
    /// every neutral surface in Nod. Ten call sites remembered to tint it and
    /// three did not, which is exactly the drift a shared modifier exists to
    /// stop: the analytics switch and the organization's tool switches sat blue
    /// beside grey ones on the same pane.
    func nodSwitch() -> some View {
        toggleStyle(.switch)
            .tint(Theme.Palette.violet)
    }
}
