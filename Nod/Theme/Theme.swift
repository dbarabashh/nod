import SwiftUI

enum Theme {
    enum Palette {
        static let bg         = Color(red: 10/255,  green: 10/255,  blue: 31/255)   // #0a0a1f
        static let bgSoft     = Color(red: 15/255,  green: 15/255,  blue: 36/255)   // #0f0f24
        static let ink        = Color(red: 245/255, green: 245/255, blue: 247/255)  // #f5f5f7
        static let graphite   = Color(red: 161/255, green: 161/255, blue: 170/255)  // #a1a1aa
        static let muted      = Color(red: 113/255, green: 113/255, blue: 122/255)  // #71717a

        static let surface        = Color.white.opacity(0.04)
        static let surfaceStrong  = Color.white.opacity(0.07)
        static let border         = Color.white.opacity(0.08)
        static let borderStrong   = Color.white.opacity(0.14)

        static let violet = Color(red: 139/255, green: 92/255,  blue: 246/255)      // #8b5cf6
        static let pink   = Color(red: 236/255, green: 72/255,  blue: 153/255)      // #ec4899
        static let cyan   = Color(red: 34/255,  green: 211/255, blue: 238/255)      // #22d3ee
        static let warning = Color(red: 245/255, green: 158/255, blue: 11/255)      // #f59e0b amber
    }

    enum Gradients {
        static let textBrand = LinearGradient(
            colors: [Palette.violet, Palette.pink, Palette.cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        static let buttonBrand = LinearGradient(
            colors: [Palette.violet, Palette.pink],
            startPoint: .leading,
            endPoint: .trailing
        )
        static let buttonSuccess = LinearGradient(
            colors: [Palette.cyan, Palette.violet],
            startPoint: .leading,
            endPoint: .trailing
        )
        static let background = LinearGradient(
            colors: [Palette.bg, Palette.bgSoft],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Radii {
        static let card: CGFloat    = 20
        static let surface: CGFloat = 16
        static let chip: CGFloat    = 10
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.Gradients.background.ignoresSafeArea()

            Circle()
                .fill(Theme.Palette.violet)
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .opacity(0.35)
                .offset(x: -130, y: -170)

            Circle()
                .fill(Theme.Palette.pink)
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .opacity(0.28)
                .offset(x: 150, y: 180)

            Circle()
                .fill(Theme.Palette.cyan)
                .frame(width: 240, height: 240)
                .blur(radius: 100)
                .opacity(0.18)
                .offset(x: 80, y: -30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
