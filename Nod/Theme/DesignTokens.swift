import SwiftUI

/// Refero "Midnight Eclipse" design tokens — colours, surfaces, spacing,
/// radii, shadows, typography helpers. Token names match the source export
/// 1:1 so they're easy to look up in the design file.
///
/// **Semantic colours** (`Theme.Palette`) alias these primitives — call sites
/// shouldn't reach in here directly except for one-off colour references.
enum DesignTokens {
    // MARK: - Palette

    enum Palette {
        static let midnightEclipse = Color(hex: 0x000000)
        static let starlessNight   = Color(hex: 0x030719)
        static let twilightInk     = Color(hex: 0x1C1D1F)
        static let ghostlyGray     = Color(hex: 0xE5E7EB)
        static let deepOcean       = Color(hex: 0x001B33)
        static let frost           = Color(hex: 0xFFFFFF)
        static let ashGray         = Color(hex: 0x333333)
        static let ironGray        = Color(hex: 0x666666)
        static let slateGray       = Color(hex: 0x70757C)
        static let pewter          = Color(hex: 0x999999)
        static let cloud           = Color(hex: 0xCCCCCC)

        // Accents
        static let electricBlue    = Color(hex: 0x0088FF)
        static let vividGreen      = Color(hex: 0x16C253)
        static let sunsetOrange    = Color(hex: 0xE6714F)
        static let goldenrod       = Color(hex: 0xFFB764)
        static let magentaBurst    = Color(hex: 0xB855E7)
        static let sunshineYellow  = Color(hex: 0xFFDD00)
        static let crimsonRed      = Color(hex: 0xFF5252)
        static let tealGlow        = Color(hex: 0x1CECBB)
        static let fuchsiaFlare    = Color(hex: 0xDD55E7)
        static let skyBlue         = Color(hex: 0x60A5FA)
    }

    // MARK: - Surfaces (elevation ladder)

    enum Surface {
        static let level0 = Palette.midnightEclipse  // page background
        static let level1 = Palette.starlessNight    // cards / sections
        static let level2 = Palette.deepOcean        // specialised cards
        static let level3 = Palette.frost            // high-contrast surfaces
    }

    // MARK: - Spacing

    enum Spacing {
        static let unit: CGFloat   = 4
        static let s4:   CGFloat   = 4
        static let s8:   CGFloat   = 8
        static let s12:  CGFloat   = 12
        static let s16:  CGFloat   = 16
        static let s20:  CGFloat   = 20
        static let s24:  CGFloat   = 24
        static let s32:  CGFloat   = 32
        static let s36:  CGFloat   = 36
        static let s40:  CGFloat   = 40
        static let s48:  CGFloat   = 48
        static let s64:  CGFloat   = 64
        static let s80:  CGFloat   = 80
        static let s96:  CGFloat   = 96
        static let s128: CGFloat   = 128
        static let s144: CGFloat   = 144
        static let s192: CGFloat   = 192
    }

    // MARK: - Radii

    enum Radius {
        static let md:    CGFloat = 4
        static let lg:    CGFloat = 9
        static let xl:    CGFloat = 12
        static let xxl:   CGFloat = 18
        static let xxxl:  CGFloat = 24
        static let xxxl2: CGFloat = 32
        static let full:  CGFloat = 999
    }

    // MARK: - Shadows

    /// SwiftUI doesn't model inset shadows — for those Refero tokens use a
    /// 1px stroke overlay at the same opacity. The drop-shadow tokens are
    /// captured here as (color, radius, x, y) tuples consumable via
    /// `.shadow(color:radius:x:y:)`.
    enum Shadow {
        typealias Drop = (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)

        static let sm:  Drop = (Color.black.opacity(0.25), 4,  0, 1)
        static let sm2: Drop = (Color.black.opacity(0.10), 6,  0, 4)
        static let sm3: Drop = (Color.black.opacity(0.08), 6,  0, 2)
        static let md:  Drop = (Color.black.opacity(0.30), 10, 0, 0)
        static let lg:  Drop = (Color.black.opacity(0.25), 20, 0, 3)
        static let xl:  Drop = (Color.black.opacity(0.40), 32, 0, 8)

        /// Inset highlights → use as `.overlay(RoundedRectangle().stroke(...))`.
        static let insetSubtle  = Color.white.opacity(0.20)
        static let insetSubtle2 = Color.white.opacity(0.25)
    }

    // MARK: - Typography

    /// Refero uses Inter as primary. Inter isn't bundled — `Font.custom`
    /// falls back to system when the family isn't installed, so this is
    /// safe to call everywhere.
    enum Typography {
        static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.custom("Inter", size: size).weight(weight)
        }

        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
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
}
