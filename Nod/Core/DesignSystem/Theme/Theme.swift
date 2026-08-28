import SwiftUI

/// Semantic theme — thin alias layer over `DesignTokens`. Call sites use
/// these slot names (`Theme.Palette.ink`, `Theme.Gradients.buttonBrand`, …)
/// so the underlying token can be swapped without diffing every view.
///
/// Slot mapping after migration to Refero "Midnight Eclipse":
///   bg / bgSoft  →  midnightEclipse / starlessNight
///   ink           →  frost
///   graphite      →  cloud
///   muted         →  slateGray
///   violet        →  magentaBurst       (legacy slot — primary purple-ish)
///   pink          →  fuchsiaFlare       (legacy slot — primary pink-ish)
///   cyan          →  electricBlue       (legacy slot — primary cool accent)
///   warning       →  goldenrod
///   success       →  vividGreen         (new)
///   danger        →  crimsonRed         (new)
enum Theme {
    enum Palette {
        // Surfaces / text
        static let bg = DesignTokens.Surface.level0
        static let bgSoft = DesignTokens.Surface.level1
        static let bgDeep = DesignTokens.Surface.level2
        static let ink = DesignTokens.Palette.frost
        static let graphite = DesignTokens.Palette.cloud
        static let muted = DesignTokens.Palette.slateGray
        /// Unselected rows and secondary labels — readable, but clearly not the
        /// thing in front. `muted` is opaque slate and sits too dark on the
        /// app's surfaces for a row somebody is meant to be able to read; both
        /// sidebars and the chat home reached for this weight by hand before it
        /// had a name.
        static let inkSecondary = ink.opacity(0.72)

        // Translucent layers (kept as alpha-on-white so glass effects survive
        // the palette swap — pure-black surfaces underneath read as flat).
        static let surface = Color.white.opacity(0.04)
        static let surfaceStrong = Color.white.opacity(0.07)
        static let border = Color.white.opacity(0.08)
        static let borderStrong = Color.white.opacity(0.14)

        // Brand accents — slot names preserved. Purple/pink retired app-wide in
        // favour of a neutral light accent (see GlassButton); both now resolve
        // to frost so every former-purple tint/glow reads neutral from one place.
        static let violet = DesignTokens.Palette.frost
        static let pink = DesignTokens.Palette.frost
        static let cyan = DesignTokens.Palette.electricBlue
        static let warning = DesignTokens.Palette.goldenrod
        static let success = DesignTokens.Palette.vividGreen
        static let danger = DesignTokens.Palette.crimsonRed

        /// The app-icon sky blue — used where a surface should carry the brand
        /// tint (e.g. the live-capture ring) rather than a status colour.
        static let brand = DesignTokens.Palette.skyBlue

        // Meeting controls — the pause/resume/end/mute tints shared by the
        // status row and the collapsed capsule, centralised here so the two
        // surfaces can't drift.
        static let controlResume = DesignTokens.Palette.mintGreen
        static let controlEnd = DesignTokens.Palette.coralRed
        static let controlEndSurface = DesignTokens.Palette.maroon
        static let controlMicMuted = DesignTokens.Palette.salmonPink
        static let controlSurface = DesignTokens.Palette.slateInk

        /// The amber eye in the screen-share visibility toggle.
        static let shareEye = DesignTokens.Palette.amber
    }

    /// Single source of truth for the primary "glass" button — the marketing
    /// site's white CTA pill ported to the app. Every glass button's fill,
    /// text, border, and shadow come from here, applied by the
    /// `.glassButtonSurface(_:)` modifier. Change a value once and every
    /// glass button across the app updates.
    enum GlassButton {
        /// Light, top-to-bottom white pill fill.
        static let fill = LinearGradient(
            colors: [
                Color.white.opacity(0.95),
                Color.white.opacity(0.80)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        /// Near-black text/icon colour (matches the site's CTA).
        static let text = DesignTokens.Palette.twilightInk
        static let border = Color.white.opacity(0.6)
        static let borderWidth: CGFloat = 0.5
        static let shadow: DesignTokens.Shadow.Drop = (Color.black.opacity(0.22), 10, 0, 4)
    }

    enum Gradients {
        /// Headline gradient — neutral light sweep (purple retired). Reads as
        /// near-white on the dark surfaces it's used over.
        static let textBrand = LinearGradient(
            colors: [
                DesignTokens.Palette.frost,
                DesignTokens.Palette.cloud
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Primary button fill — aliases the single `GlassButton` source so any
        /// remaining `buttonBrand` call site renders the same glass pill. Pair
        /// with `GlassButton.text` for the label colour.
        static let buttonBrand = GlassButton.fill

        static let buttonSuccess = LinearGradient(
            colors: [
                DesignTokens.Palette.tealGlow,
                DesignTokens.Palette.electricBlue
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let background = LinearGradient(
            colors: [
                DesignTokens.Surface.level0,
                DesignTokens.Surface.level1
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Radii {
        static let card: CGFloat = DesignTokens.Radius.xxl // 18 (was 20)
        static let surface: CGFloat = DesignTokens.Radius.xl // 12 (was 16)
        static let chip: CGFloat = DesignTokens.Radius.lg //  9 (was 10)
    }
}
