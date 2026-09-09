import AppKit
import SwiftUI

/// Refero "Midnight Eclipse" design tokens — colours, surfaces, spacing,
/// radii, shadows, typography helpers. Token names match the source export, so
/// a slot that IS here is easy to look up in the design file; the export's
/// unused colours are not carried, because a themed token costs a light value
/// somebody has to pick and maintain.
///
/// The palette is a set of literal primitives; anything that has to change
/// between Light and Dark is composed from two of them with `Color.themed`.
///
/// **Semantic colours** (`Theme.Palette`) alias these primitives — call sites
/// shouldn't reach in here directly except for one-off colour references.
enum DesignTokens {
    // MARK: - Palette

    enum Palette {
        // hellonod.app's own black (its web manifest `theme_color`) and one
        // step up from it. Pure black is reserved for the capture surface,
        // which has a physical bezel to match; a whole window painted in it
        // reads as a hole rather than a surface.
        static let obsidian        = Color(hex: 0x0B0E16)
        static let obsidianRaised  = Color(hex: 0x151926)
        static let twilightInk     = Color(hex: 0x1C1D1F)
        static let frost           = Color(hex: 0xFFFFFF)
        static let slateGray       = Color(hex: 0x70757C)
        static let cloud           = Color(hex: 0xCCCCCC)

        /// What a translucent layer over a surface is made of: white on dark,
        /// black on light. Aliased as `Theme.Palette.overlay`, which is what
        /// call sites use.
        static let overlay = Color.themed(light: .black, dark: .white)

        // Light-theme surfaces and text. The dark ladder bottoms out at pure
        // black; the light one tops out at pure white and steps down, so the
        // same elevation reads as "further forward" in both.
        static let linen           = Color(hex: 0xF4F5F7)
        static let charcoal        = Color(hex: 0x4A4D52)
        static let stoneGray       = Color(hex: 0x5F646B)

        // Accents
        static let electricBlue    = Color(hex: 0x0088FF)
        static let vividGreen      = Color(hex: 0x16C253)
        static let goldenrod       = Color(hex: 0xFFB764)
        static let crimsonRed      = Color(hex: 0xFF5252)
        static let skyBlue         = Color(hex: 0x60A5FA)

        // Light-theme accents. The dark set is tuned to glow on black and goes
        // pale and unreadable on white — each one is the same hue carried down
        // to a weight that holds contrast against a light surface.
        static let electricBlueDeep = Color(hex: 0x0069CC)
        static let vividGreenDeep   = Color(hex: 0x0E9A45)
        static let goldenrodDeep    = Color(hex: 0xA96A00)
        static let crimsonRedDeep   = Color(hex: 0xCE2B2B)
        static let skyBlueDeep      = Color(hex: 0x2F6FE0)

        // App control tints — opaque colors used by the meeting controls. Kept as
        // exact RGB (not hex) to preserve the values
        // lifted verbatim from the original inline view code.
        static let coralRed        = Color(red: 0.95, green: 0.45, blue: 0.50)
        static let maroon          = Color(red: 0.55, green: 0.18, blue: 0.22)
        static let salmonPink      = Color(red: 0.95, green: 0.55, blue: 0.55)

        // Light-theme control tints — the same roles, inverted: the tints go
        // darker so they read on a light chip, the chips go paler.
        // hellonod.app's hero gradient, ported from nod-landing's
        // `HeroBackdrop`. Every stop is hue-locked to 211° — the blue of the
        // macOS app icon — so the sky behind sign-in and onboarding is the same
        // blue a user just saw on the site. Keep the two in step.
        static let heroDeep        = Color(hex: 0x06478C)
        static let heroAzure       = Color(hex: 0x0075F2)
        static let heroSky         = Color(hex: 0x65A5F6)

        static let coralRedDeep    = Color(hex: 0xC93F3A)
        static let salmonPinkDeep  = Color(hex: 0xC9524B)
        static let blushSurface    = Color(hex: 0xFBE3E3)
    }

    // MARK: - Surfaces (elevation ladder)

    enum Surface {
        static let level0 = Color.themed(light: Palette.frost, dark: Palette.obsidian)
        static let level1 = Color.themed(light: Palette.linen, dark: Palette.obsidianRaised)
    }

    // MARK: - Radii

    /// On the 4pt grid, like everything else. These were 9 / 12 / 18 — one
    /// step on the grid, two off it — which is how a chip and the field beside
    /// it came to round differently by a point nobody chose.
    enum Radius {
        static let lg:    CGFloat = 8
        static let xl:    CGFloat = 12
        static let xxl:   CGFloat = 16
    }

    // MARK: - Shadows

    enum Shadow {
        typealias Drop = (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)

        /// Every drop shadow's colour. Light carries roughly half the opacity:
        /// the same shadow that reads as depth against black reads as dirt
        /// against white. Radius and offset stay at the call site — they are
        /// what makes one surface float higher than another.
        static func ink(light: Double, dark: Double) -> Color {
            .themed(light: .black.opacity(light), dark: .black.opacity(dark))
        }
    }
}

// MARK: - Hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// SwiftUI has no equivalent primitive on macOS 13 — a `Color` is a single
    /// value, and `@Environment(\.colorScheme)` can only be read inside a
    /// `View`. `NSColor`'s dynamic provider is asked for a colour at draw time,
    /// with the appearance in hand, so a token stays a plain `static let`.
    static func themed(light: Color, dark: Color) -> Color {
        Color(nsColor: .themed(light: NSColor(light), dark: NSColor(dark)))
    }
}

extension NSColor {
    /// For the few surfaces drawn by AppKit rather than SwiftUI. Kept as
    /// `NSColor` end to end — round-tripping a themed `Color` back through
    /// `NSColor(_:)` is not documented to preserve the provider.
    static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
