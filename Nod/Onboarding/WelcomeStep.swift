import SwiftUI

struct WelcomeStep: View {
    let strings: OnboardingStrings
    let currentLanguage: AppLanguage
    /// Receives the user's final language pick — committed only when they tap
    /// Continue, so an exploratory menu tap doesn't persist if they abandon
    /// onboarding.
    let onContinue: (AppLanguage) -> Void

    @State private var selection: AppLanguage

    init(
        strings: OnboardingStrings,
        currentLanguage: AppLanguage,
        onContinue: @escaping (AppLanguage) -> Void
    ) {
        self.strings = strings
        self.currentLanguage = currentLanguage
        self.onContinue = onContinue
        self._selection = State(initialValue: currentLanguage)
    }

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
                .padding(.bottom, 28)

            VStack(spacing: 16) {
                ForEach(Array(strings.welcomeBullets.enumerated()), id: \.offset) { _, bullet in
                    FeatureRow(icon: bullet.icon, text: bullet.text)
                }
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 24)

            LanguageRow(
                label: strings.welcomeLanguageLabel,
                selection: $selection
            )
            .frame(maxWidth: 380)

            Spacer(minLength: 0)

            Button(action: { onContinue(selection) }) {
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

private struct LanguageRow: View {
    let label: String
    @Binding var selection: AppLanguage

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.violet)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.Palette.violet.opacity(0.10))
                        .overlay(Circle().stroke(Theme.Palette.violet.opacity(0.25), lineWidth: 0.5))
                )

            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.88))

            Spacer(minLength: 0)

            // Picker with .menu style handles selection-state semantics,
            // VoiceOver "selected" announcements, and keyboard interaction
            // correctly — including the Return-key conflict with the
            // Continue button's `.keyboardShortcut(.defaultAction)`. The
            // raw `Menu` previously here had to fake all of that.
            Picker("Language", selection: $selection) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Stable trigger width so the row doesn't jitter as the
            // user steps through native names with wildly different
            // glyph widths (中文 vs Українська).
            .frame(minWidth: 140, alignment: .trailing)
        }
    }
}
