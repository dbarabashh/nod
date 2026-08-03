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
        _selection = State(initialValue: currentLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("NodGlyphInk")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
                .padding(.bottom, 18)

            Text(strings.welcomeTitle)
                .font(.system(size: 30, weight: .semibold, design: .default))
                .foregroundStyle(Theme.GlassButton.text)
                .padding(.bottom, 8)

            Text(strings.welcomeTagline)
                .multilineTextAlignment(.center)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: 380)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                ForEach(Array(strings.welcomeBullets.enumerated()), id: \.offset) { _, bullet in
                    FeatureRow(icon: bullet.icon, text: bullet.text)
                }
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 6) {
                LanguageRow(
                    label: strings.welcomeLanguageLabel,
                    selection: $selection
                )
                Text(strings.welcomeLanguageHint)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 30)

            Button(action: { onContinue(selection) }) {
                Text(strings.welcomeContinue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(Theme.GlassButton.text.opacity(0.85))
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
                .foregroundStyle(Theme.Palette.cyan)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.Palette.cyan.opacity(0.10))
                        .overlay(Circle().stroke(Theme.Palette.cyan.opacity(0.25), lineWidth: 0.5))
                )

            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.GlassButton.text.opacity(0.85))

            Spacer(minLength: 0)

            // Picker with .menu style handles selection-state semantics,
            // VoiceOver "selected" announcements, and keyboard interaction
            // correctly — including the Return-key conflict with the
            // Continue button's `.keyboardShortcut(.defaultAction)`. The
            // raw `Menu` previously here had to fake all of that.
            Picker("Nod language", selection: $selection) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Stable trigger width so the row doesn't jitter as the
            // user steps through native names with wildly different
            // glyph widths (中文 vs Українська).
            .frame(minWidth: 130, alignment: .trailing)
        }
    }
}
