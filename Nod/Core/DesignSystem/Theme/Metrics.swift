import SwiftUI

/// The 4pt grid: spacing, layout widths and control sizes.
///
/// Where the numbers came from, and what was deliberately left behind:
/// `docs/design-scale.md`.
extension Theme {
    /// Every gap in the app is one of these.
    enum Space {
        /// Icon to its label; the pause inside a chip.
        static let x1: CGFloat = 4
        /// Inside a row; between chips.
        static let x2: CGFloat = 8
        /// Sidebar padding; a compact group.
        static let x3: CGFloat = 12
        /// Card and field padding; modal edges.
        static let x4: CGFloat = 16
        /// Between sections; card to card; title to body.
        static let x6: CGFloat = 24
        /// The large block rhythm.
        static let x8: CGFloat = 32
        /// Onboarding content inset.
        static let x10: CGFloat = 40
        /// Hero and empty-state separation.
        static let x12: CGFloat = 48
    }

    /// How wide things are, and where they sit.
    ///
    /// The content column is not offset from the sidebar by hand — it is
    /// centred in whatever main pane is left. That single decision is why a
    /// card on Settings, on Help and on Home all measure the same, and why
    /// they stay that way when the sidebar changes width.
    enum Layout {
        /// The smallest step on the grid that fits every row a person navigates
        /// by — the source measurement's 152 does not, because this app
        /// navigates by phrases. `SidebarFitTests` holds it to the labels.
        static let sidebar: CGFloat = 188
        /// Settings, Home and any list of cards.
        static let content: CGFloat = 488
        /// Prose. Wider than `content` because a paragraph reads badly at a
        /// card's width and a card reads badly at a paragraph's.
        static let editor: CGFloat = 520
        /// The minimum breathing room either side of a centred column.
        static let pageInset: CGFloat = Space.x6
    }

    /// Control sizes. Two heights, not seven: one for anything a person aims
    /// at as the point of the screen, one for anything that lives in a toolbar.
    enum Control {
        static let height: CGFloat = 40
        static let heightCompact: CGFloat = 32

        static let icon: CGFloat = 16
        static let iconMicro: CGFloat = 12
    }
}
