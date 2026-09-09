import SwiftUI

/// What the welcome step settled: the language, the name to use, and the two
/// diagnostics switches — the only things worth asking before Nod has done
/// anything for the person.
struct WelcomeAnswers {
    let language: AppLanguage
    let name: String
    let sendsCrashReports: Bool
    let sharesUsage: Bool
}

/// The first thing a new account sees: Nod introducing itself by name, and
/// the few settings that cannot wait — what language to answer in, what to
/// call the person, and whether diagnostics may leave the Mac. One screen and
/// one button; the permissions and the calendar wait for the notch, where the
/// person will actually meet them.
struct WelcomeStep: View {
    let strings: OnboardingStrings
    /// Who is being greeted, when the account carries a name. Without one the
    /// greeting drops rather than saying "Hi there": a stand-in is worse than
    /// nothing on the one line that proves this was meant for them.
    let firstName: String?
    /// Receives everything picked — committed only when they tap Continue, so
    /// an exploratory menu tap doesn't persist if they abandon onboarding.
    let onContinue: (WelcomeAnswers) -> Void

    @State private var selection: AppLanguage
    @State private var name: String
    @State private var sendsCrashReports: Bool
    @State private var sharesUsage: Bool

    /// `initialName` is seeded from the account so Continue never blanks a
    /// name the person already has.
    init(
        strings: OnboardingStrings,
        firstName: String?,
        currentLanguage: AppLanguage,
        initialName: String,
        initialSendsCrashReports: Bool,
        initialSharesUsage: Bool,
        onContinue: @escaping (WelcomeAnswers) -> Void
    ) {
        self.strings = strings
        self.firstName = firstName
        self.onContinue = onContinue
        _selection = State(initialValue: currentLanguage)
        _name = State(initialValue: initialName)
        _sendsCrashReports = State(initialValue: initialSendsCrashReports)
        _sharesUsage = State(initialValue: initialSharesUsage)
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

            VStack(alignment: .leading, spacing: 14) {
                SettingRow(icon: "nc-user", label: "Your name") {
                    TextField("Alex", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.95))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    LanguageRow(label: strings.welcomeLanguageLabel, selection: $selection)
                    Text(strings.welcomeLanguageHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SwitchRow(icon: "nc-triangle-warning", label: "Send crash reports", isOn: $sendsCrashReports)
                    SwitchRow(icon: "nc-window-chart-line", label: "Share usage events", isOn: $sharesUsage)
                    Text("Neither ever includes what you say or write. Both can be changed any time in Settings → Privacy.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 30)

            OnboardingPrimaryButton(strings.welcomeContinue, action: submit)
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

    private func submit() {
        onContinue(
            WelcomeAnswers(
                language: selection,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                sendsCrashReports: sendsCrashReports,
                sharesUsage: sharesUsage
            )
        )
    }
}

/// One row of the screen: a glyph, what the row is, and its control on the
/// trailing edge.
private struct SettingRow<Control: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            RowGlyph(icon: icon)
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            Spacer(minLength: 0)
            control
        }
    }
}

private struct SwitchRow: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, label: label) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .nodSwitch()
                .accessibilityLabel(label)
        }
    }
}

private struct RowGlyph: View {
    let icon: String

    var body: some View {
        Image(icon)
            .icon(13)
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: 22, height: 22)
            .skySurface(Circle())
    }
}

private struct LanguageRow: View {
    let label: String
    @Binding var selection: AppLanguage

    var body: some View {
        SettingRow(icon: "nc-earth", label: label) {
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
        WelcomeStep(
            strings: .english,
            firstName: "Dima",
            currentLanguage: .english,
            initialName: "Dima Barabash",
            initialSendsCrashReports: true,
            initialSharesUsage: true,
            onContinue: { _ in }
        )
    }
    .frame(width: 720, height: 660)
}
