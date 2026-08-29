import SwiftUI

/// The sky behind sign-in and onboarding: hellonod.app's hero blue.
///
/// It carries the colour-scheme pin as well as the gradient. The ground is a
/// saturated blue in every theme, so content on it is white in every theme —
/// which is what `.dark` buys: `Theme.Palette.ink` resolves to white, and
/// `Theme.GlassButton.text` to the dark label a white pill needs. Left to
/// follow the app's Appearance setting, half these screens would render dark
/// text on blue.
struct WelcomeBackdrop<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Theme.Gradients.welcome
                .ignoresSafeArea()

            content()
                .environment(\.colorScheme, .dark)
        }
    }
}
