import SwiftUI

/// The last onboarding step: what, if anything, we may email about. Nothing is
/// preselected, and skipping is a real answer — it records "none of these" so the
/// account is never asked again and never enrolled by default.
struct EmailConsentStep: View {
    @ObservedObject var preferences: EmailPreferenceService
    let onFinish: () -> Void

    @State private var selected: Set<EmailTopic> = []

    var body: some View {
        VStack(spacing: 0) {
            Text("Stay in the loop — only if you want")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 8)

            Text(
                "Pick anything that would be useful. All three are off unless you choose them, "
                    + "and you can change your choices in Settings at any time."
            )
            .multilineTextAlignment(.center)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Palette.inkSecondary)
            .frame(maxWidth: 440)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            EmailConsentChoiceList(selected: $selected, isDisabled: preferences.isBusy)
                .frame(maxWidth: 440)

            if let error = preferences.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(.top, 10)
            }

            PolicyFooter(
                primary: TitledAction(preferences.isSavingPrompt ? "Saving…" : "Finish setup") { save(nothing: false) },
                secondary: TitledAction("Not now") { save(nothing: true) },
                isBusy: preferences.isBusy,
                style: .onboarding
            )
            .frame(maxWidth: 440)
            .padding(.top, 16)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await preferences.refresh()
            // Already answered on another device — don't ask the same question
            // again just because this Mac finished onboarding later.
            if preferences.hasLoaded, !preferences.shouldPresentFullPrompt {
                onFinish()
            }
        }
    }

    private func save(nothing: Bool) {
        Task {
            if await preferences.savePromptSelection(nothing ? [] : selected, source: .onboardingPrompt) {
                onFinish()
            } else if !preferences.hasLoaded {
                // Offline or signed out: onboarding must not become a dead end.
                onFinish()
            }
        }
    }
}

#Preview {
    EmailConsentStep(preferences: EmailPreferenceService(), onFinish: {})
        .frame(width: 720, height: 660)
        .background(WindowBackdrop())
}
