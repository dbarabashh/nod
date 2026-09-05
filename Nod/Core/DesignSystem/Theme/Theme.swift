import SwiftUI

/// Semantic theme — thin alias layer over `DesignTokens`. Call sites use
/// these slot names (`Theme.Palette.ink`, `Theme.Gradients.buttonBrand`, …)
/// so the underlying token can be swapped without diffing every view.
///
/// Every slot that has to differ between Light and Dark is a `Color.themed`
/// pair, resolved at draw time against the appearance the view is rendered
/// in — so a call site never asks which theme is on.
///
/// Slot mapping in Dark ("Midnight Eclipse"):
///   bg / bgSoft  →  obsidian / obsidianRaised
///   ink           →  frost
///   graphite      →  cloud
///   muted         →  slateGray
///   violet        →  magentaBurst       (legacy slot — primary purple-ish)
///   cyan          →  electricBlue       (legacy slot — primary cool accent)
///   warning       →  goldenrod
///   success       →  vividGreen         (new)
///   danger        →  crimsonRed         (new)
enum Theme {
    enum Palette {
        // Surfaces / text
        static let bg = DesignTokens.Surface.level0
        static let bgSoft = DesignTokens.Surface.level1
        static let ink = Color.themed(light: DesignTokens.Palette.twilightInk, dark: DesignTokens.Palette.frost)
        static let graphite = Color.themed(light: DesignTokens.Palette.charcoal, dark: DesignTokens.Palette.cloud)
        static let muted = Color.themed(light: DesignTokens.Palette.stoneGray, dark: DesignTokens.Palette.slateGray)
        /// Unselected rows and secondary labels — readable, but clearly not the
        /// thing in front. `muted` is opaque slate and sits too dark on the
        /// app's surfaces for a row somebody is meant to be able to read; both
        /// sidebars and the chat home reached for this weight by hand before it
        /// had a name.
        static let inkSecondary = ink.opacity(0.72)

        /// Every scrim, hairline, and hover wash in the app reads from here
        /// rather than from `Color.white`, so all of them invert together with
        /// one token instead of one call site at a time.
        static let overlay = DesignTokens.Palette.overlay

        /// The label colour that goes *on top of* an accent fill — the accent
        /// is near-white in Dark and near-black in Light, so this is its
        /// opposite in both.
        static let onAccent = Color.themed(light: DesignTokens.Palette.frost, dark: DesignTokens.Palette.twilightInk)

        /// `ink`'s AppKit twin, for the composer's `NSTextView`. Declared beside
        /// the token it mirrors so the pair is edited once.
        static let inkNS = NSColor.themed(light: NSColor(DesignTokens.Palette.twilightInk), dark: .white)

        // Translucent layers, built on `overlay` so glass effects survive the
        // theme swap — a white wash on a light surface is invisible, and a
        // black one on a black surface is worse.
        static let surface = overlay.opacity(0.04)
        static let surfaceStrong = overlay.opacity(0.07)
        static let border = overlay.opacity(0.08)
        static let borderStrong = overlay.opacity(0.14)
        /// The dim behind a modal. Black in both themes on purpose — a light
        /// scrim over a light surface doesn't read as "the thing behind is out
        /// of reach", which is the whole job.
        static let scrim = Color.black.opacity(0.28)

        /// The user's own turn — the chat bubble and the composer's mention
        /// pills, which have to be the same chrome and live in two files.
        static let userTurn = overlay.opacity(0.14)

        // Brand accents — slot names preserved. Purple retired app-wide in
        // favour of a neutral accent (see GlassButton); it now resolves to
        // `ink` so every former-purple tint/glow reads neutral from one place.
        static let violet = ink
        static let cyan = Color.themed(light: DesignTokens.Palette.electricBlueDeep, dark: DesignTokens.Palette.electricBlue)
        static let warning = Color.themed(light: DesignTokens.Palette.goldenrodDeep, dark: DesignTokens.Palette.goldenrod)
        static let success = Color.themed(light: DesignTokens.Palette.vividGreenDeep, dark: DesignTokens.Palette.vividGreen)
        static let danger = Color.themed(light: DesignTokens.Palette.crimsonRedDeep, dark: DesignTokens.Palette.crimsonRed)

        /// The app-icon sky blue — used where a surface should carry the brand
        /// tint (e.g. the live-capture ring) rather than a status colour.
        static let brand = Color.themed(light: DesignTokens.Palette.skyBlueDeep, dark: DesignTokens.Palette.skyBlue)

        // Meeting controls — the pause/resume/end/mute tints shared by the
        // status row and the collapsed capsule, centralised here so the two
        // surfaces can't drift.
        static let controlEnd = Color.themed(light: DesignTokens.Palette.coralRedDeep, dark: DesignTokens.Palette.coralRed)
        static let controlEndSurface = Color.themed(light: DesignTokens.Palette.blushSurface, dark: DesignTokens.Palette.maroon)
        static let controlMicMuted = Color.themed(light: DesignTokens.Palette.salmonPinkDeep, dark: DesignTokens.Palette.salmonPink)
    }

    /// Single source of truth for the primary "glass" button — the marketing
    /// site's white CTA pill ported to the app. Every glass button's fill,
    /// text, border, and shadow come from here, applied by the
    /// `.glassButtonSurface(_:)` modifier. Change a value once and every
    /// glass button across the app updates.
    ///
    /// The pill is the inverse of the surface it sits on: a white pill on
    /// black, a near-black pill on white. Inverting only the fill and keeping
    /// the dark label would leave the Light theme's primary action invisible.
    enum GlassButton {
        static let fill = LinearGradient(
            colors: [
                Palette.ink.opacity(0.95),
                Palette.ink.opacity(0.80)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        static let text = Palette.onAccent
        static let border = Palette.ink.opacity(0.6)
        static let borderWidth: CGFloat = 0.5
        static let shadow: DesignTokens.Shadow.Drop = (DesignTokens.Shadow.ink(light: 0.14, dark: 0.22), 10, 0, 4)
    }

    enum Gradients {
        /// Primary button fill — aliases the single `GlassButton` source so any
        /// remaining `buttonBrand` call site renders the same glass pill. Pair
        /// with `GlassButton.text` for the label colour.
        static let buttonBrand = GlassButton.fill

        /// The sky behind sign-in and onboarding — hellonod.app's hero blue.
        /// Deep at the top, sky at the bottom, and it never dissolves to white:
        /// the site's other variant fades out by the last third, and the white
        /// content standing there would go with it.
        static let welcome = LinearGradient(
            stops: [
                .init(color: DesignTokens.Palette.heroDeep, location: 0),
                .init(color: DesignTokens.Palette.heroAzure, location: 0.30),
                .init(color: DesignTokens.Palette.heroSky, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    enum Radii {
        static let card: CGFloat = DesignTokens.Radius.xxl
        static let surface: CGFloat = DesignTokens.Radius.xl
        static let chip: CGFloat = DesignTokens.Radius.lg
    }
}
