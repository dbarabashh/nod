import SwiftUI

struct WelcomeStep: View {
    let strings: OnboardingStrings
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image("NodLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 76, height: 76)
                .shadow(color: Theme.Palette.violet.opacity(0.35), radius: 28, x: 0, y: 12)
                .padding(.bottom, 24)

            Text(strings.welcomeTitle)
                .font(.system(size: 30, weight: .semibold, design: .default))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 10)

            Text(strings.welcomeTagline)
                .multilineTextAlignment(.center)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .frame(maxWidth: 380)
                .padding(.bottom, 36)

            VStack(spacing: 16) {
                ForEach(Array(strings.welcomeBullets.enumerated()), id: \.offset) { _, bullet in
                    FeatureRow(icon: bullet.icon, text: bullet.text)
                }
            }
            .frame(maxWidth: 380)

            Spacer(minLength: 0)

            Button(action: onContinue) {
                Text(strings.welcomeContinue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Gradients.buttonBrand)
                    )
                    .shadow(color: Theme.Palette.pink.opacity(0.3), radius: 18, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 40)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.cyan)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.Palette.cyan.opacity(0.10))
                        .overlay(Circle().stroke(Theme.Palette.cyan.opacity(0.25), lineWidth: 0.5))
                )

            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
