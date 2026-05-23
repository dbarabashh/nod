import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("NodLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: Theme.Palette.violet.opacity(0.4), radius: 20, x: 0, y: 8)

            VStack(spacing: 10) {
                Text("Welcome to Nod")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.Gradients.textBrand)

                Text("Your meeting copilot. We'll need access to your microphone and screen audio to listen along.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .frame(maxWidth: 380)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Gradients.buttonBrand)
                    )
                    .shadow(color: Theme.Palette.pink.opacity(0.35), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 12)
        }
        .padding(32)
    }
}
