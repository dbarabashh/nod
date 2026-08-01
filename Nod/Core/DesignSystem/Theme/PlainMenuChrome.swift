import SwiftUI

extension View {
    /// Strips a `Menu` back to its label, so a hand-drawn row or pill can be the
    /// trigger.
    ///
    /// `.button`, not `.borderlessButton`: the borderless style lays the label
    /// out on its own terms — it centres the title and drops anything beside it,
    /// which is how a status light and a trailing value disappear from a row.
    ///
    /// Carried here because the reason is easy to get wrong and three surfaces
    /// now depend on it (`HomeSidebar`'s Capture pill, the ambient-context row,
    /// `PanelChrome`'s header glyph).
    func plainMenuChrome() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}
