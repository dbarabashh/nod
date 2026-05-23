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
        static let bg            = DesignTokens.Surface.level0
        static let bgSoft        = DesignTokens.Surface.level1
        static let bgDeep        = DesignTokens.Surface.level2
        static let ink           = DesignTokens.Palette.frost
        static let graphite      = DesignTokens.Palette.cloud
        static let muted         = DesignTokens.Palette.slateGray

        // Translucent layers (kept as alpha-on-white so glass effects survive
        // the palette swap — pure-black surfaces underneath read as flat).
        static let surface       = Color.white.opacity(0.04)
        static let surfaceStrong = Color.white.opacity(0.07)
        static let border        = Color.white.opacity(0.08)
        static let borderStrong  = Color.white.opacity(0.14)

        // Brand accents — slot names preserved; values come from new palette.
        static let violet        = DesignTokens.Palette.magentaBurst
        static let pink          = DesignTokens.Palette.fuchsiaFlare
        static let cyan          = DesignTokens.Palette.electricBlue
        static let warning       = DesignTokens.Palette.goldenrod
        static let success       = DesignTokens.Palette.vividGreen
        static let danger        = DesignTokens.Palette.crimsonRed
    }

    enum Gradients {
        /// Headline gradient — magenta → fuchsia → electric blue.
        /// Replaces the old violet/pink/cyan aurora; same warm-to-cool sweep.
        static let textBrand = LinearGradient(
            colors: [
                DesignTokens.Palette.magentaBurst,
                DesignTokens.Palette.fuchsiaFlare,
                DesignTokens.Palette.electricBlue
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let buttonBrand = LinearGradient(
            colors: [
                DesignTokens.Palette.magentaBurst,
                DesignTokens.Palette.fuchsiaFlare
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

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
        static let card:    CGFloat = DesignTokens.Radius.xxl   // 18 (was 20)
        static let surface: CGFloat = DesignTokens.Radius.xl    // 12 (was 16)
        static let chip:    CGFloat = DesignTokens.Radius.lg    //  9 (was 10)
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.Gradients.background.ignoresSafeArea()

            Circle()
                .fill(DesignTokens.Palette.magentaBurst)
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .opacity(0.30)
                .offset(x: -130, y: -170)

            Circle()
                .fill(DesignTokens.Palette.fuchsiaFlare)
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .opacity(0.24)
                .offset(x: 150, y: 180)

            Circle()
                .fill(DesignTokens.Palette.electricBlue)
                .frame(width: 240, height: 240)
                .blur(radius: 100)
                .opacity(0.16)
                .offset(x: 80, y: -30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
