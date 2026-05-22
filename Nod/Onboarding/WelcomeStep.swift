import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(Color(red: 0.62, green: 0.82, blue: 1.0))

            VStack(spacing: 8) {
                Text("Welcome to Nod")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Your meeting copilot. We'll need access to your microphone and screen audio to listen along.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(maxWidth: 380)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous).fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.55, blue: 0.95),
                                    Color(red: 0.55, green: 0.30, blue: 0.90)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
                    .shadow(color: Color(red: 0.30, green: 0.55, blue: 0.95).opacity(0.4), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 12)
        }
        .padding(32)
    }
}
