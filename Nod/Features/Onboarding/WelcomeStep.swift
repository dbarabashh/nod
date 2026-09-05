import SwiftUI

/// The first thing a new account sees: Nod introducing itself by name, and
/// asking what language to answer in. One question and one button — the
/// permissions, the calendar and the first question all wait for the notch,
/// where the person will actually meet them.
struct WelcomeStep: View {
    let strings: OnboardingStrings
    /// Who is being greeted, when the account carries a name. Without one the
    /// greeting drops rather than saying "Hi there": a stand-in is worse than
    /// nothing on the one line that proves this was meant for them.
    let firstName: String?
    let currentLanguage: AppLanguage
    /// Receives the user's final language pick — committed only when they tap
    /// Continue, so an exploratory menu tap doesn't persist if they abandon
    /// onboarding.
    let onContinue: (AppLanguage) -> Void

    @State private var selection: AppLanguage

    init(
        strings: OnboardingStrings,
        firstName: String?,
        currentLanguage: AppLanguage,
        onContinue: @escaping (AppLanguage) -> Void
    ) {
        self.strings = strings
        self.firstName = firstName
        self.currentLanguage = currentLanguage
        self.onContinue = onContinue
        _selection = State(initialValue: currentLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            NotchCollector(size: 88)
                .padding(.bottom, 26)

            Text(greeting)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 6)

            Text(strings.welcomeTagline)
                .multilineTextAlignment(.center)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 6) {
                LanguageRow(label: strings.welcomeLanguageLabel, selection: $selection)
                Text(strings.welcomeLanguageHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 30)

            Button(action: { onContinue(selection) }, label: {
                Text(strings.welcomeContinue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .glassButtonSurface(Capsule(style: .continuous))
            })
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var greeting: String {
        guard let firstName else { return strings.welcomeTitle }
        return "Hi, \(firstName)."
    }
}

private struct LanguageRow: View {
    let label: String
    @Binding var selection: AppLanguage

    var body: some View {
        HStack(spacing: 14) {
            Image("nc-earth")
                .icon(13)
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.Palette.overlay.opacity(0.12))
                        .overlay(Circle().stroke(Theme.Palette.overlay.opacity(0.28), lineWidth: 0.5))
                )

            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))

            Spacer(minLength: 0)

            // A `Menu` over `LanguageMenu`, not a flat `Picker`. A `Picker`
            // renders one list of every language, which at thirty-five runs off
            // the bottom of the screen; only a menu can hold the submenus that
            // keep it short. The two things the `Picker` was here for both
            // survive: `LanguageMenu` marks the selection with a `Toggle`, so
            // AppKit draws the checked item VoiceOver announces, and an open
            // menu tracks its own key events — Return picks the highlighted
            // language rather than falling through to Continue's
            // `.keyboardShortcut(.defaultAction)`.
            Menu {
                LanguageMenu(selected: selection) { selection = $0 }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.nativeName)
                        .font(.system(size: 13, weight: .medium))
                    Image("nc-chevron-expand-y")
                        .icon(8)
                }
                .foregroundStyle(Theme.Palette.ink.opacity(0.95))
            }
            .plainMenuChrome()
            .accessibilityLabel("Nod language")
            .accessibilityValue(selection.nativeName)
            // Stable trigger width so the row doesn't jitter as the
            // user steps through native names with wildly different
            // glyph widths (中文 vs Українська).
            .frame(minWidth: 130, alignment: .trailing)
        }
    }
}

#Preview {
    WelcomeBackdrop {
        WelcomeStep(strings: .english, firstName: "Dima", currentLanguage: .english, onContinue: { _ in })
    }
    .frame(width: 720, height: 660)
}
