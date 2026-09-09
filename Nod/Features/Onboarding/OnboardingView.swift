import SwiftUI

struct OnboardingView: View {
    /// The window's part is over: the flow moves to the notch. The coordinator
    /// closes this window and hands `OnboardingState` to `NotchModel`.
    let onHandoff: () -> Void

    @EnvironmentObject private var state: OnboardingState
    @EnvironmentObject private var language: LanguagePreference
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var telemetry: OnboardingTelemetry
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var consent: ConsentPreference
    @EnvironmentObject private var rehearsal: TalkRehearsal

    /// Pad past the traffic-light strip so step titles never collide with the
    /// close button. macOS chrome occupies ~28pt of the window's top.
    private static let chromeInset: CGFloat = 48

    /// True once the profile fetch has finished — successfully or not. Gates
    /// only the profile step; every other step is independent of it.
    @State private var profileLoaded = false
    /// The name typed on the welcome step, greeted by on the next before the
    /// profile save has come back.
    @State private var typedName: String?

    var body: some View {
        WelcomeBackdrop {
            VStack(spacing: 0) {
                // Reserve the traffic-light strip as a sibling so it subtracts
                // from the content height instead of overflowing a full-height
                // step (which clipped the bottom buttons).
                Color.clear.frame(height: Self.chromeInset)
                content
                OnboardingProgress(step: state.status.currentStep)
                    .padding(.bottom, 20)
            }
        }
        // Fills whatever the window is rather than asking for a size: the
        // window owns it (`WindowCoordinator.onboardingSize`), and a step that
        // states its own is a step that moves the frame when you reach it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Onboarding can run against an account that already has a profile —
        // a reinstall, a second Mac, a repeat of the flow. Load it so the step
        // seeds from what's stored instead of blanking it on Continue.
        //
        // The flag is what makes the load matter: `ProfileStep` reads its
        // seeds into `@State` at construction, and `@State` ignores every later
        // value. Rendering the step before the row arrives would seed it empty
        // and quietly clear the stored profile on Continue.
        .task {
            await profileStore.load()
            profileLoaded = true
        }
        .task(id: state.status.currentStep) {
            telemetry.stepShown(state.status.currentStep)
            if state.status.currentStep == .notch { onHandoff() }
        }
    }

    private var strings: OnboardingStrings {
        .english
    }

    /// A name the user already saved wins over the one Google handed us — they
    /// may have shortened it on purpose.
    private var seededName: String {
        let stored = profileStore.profile?.displayName ?? ""
        return stored.isEmpty ? (auth.session?.user.profileDisplayName ?? "") : stored
    }

    private var greetedName: String? {
        PersonName.first(of: typedName ?? seededName)
    }

    @ViewBuilder
    private var content: some View {
        switch state.status.currentStep {
        case .welcome where !profileLoaded:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .welcome:
            // Everything here is committed only when the user actually
            // advances past Welcome — so an exploratory tap in the language
            // picker doesn't persist if they close onboarding mid-flow.
            WelcomeStep(
                strings: strings,
                firstName: greetedName,
                currentLanguage: language.current,
                initialName: seededName,
                initialSendsCrashReports: CrashReporting.currentChoice(),
                initialSharesUsage: !analytics.isOptedOut,
                onContinue: { answers in
                    language.current = answers.language
                    consent.applyDiagnosticsChoice(
                        crashReports: answers.sendsCrashReports,
                        usageEvents: answers.sharesUsage,
                        analytics: analytics
                    )
                    // Fire-and-forget: the name is a nice-to-have, never a
                    // blocker. A transient save failure leaves the stored
                    // name as it was (recoverable in Settings).
                    if !answers.name.isEmpty, answers.name != profileStore.profile?.displayName {
                        typedName = answers.name
                        Task {
                            try? await profileStore.update { $0.displayName = answers.name }
                        }
                    }
                    state.goNext()
                }
            )
        case .talk:
            TalkStep(
                rehearsal: rehearsal,
                firstName: greetedName,
                onContinue: { state.goNext() },
                onSkip: { state.goNext() }
            )
        case .notch, .calendar, .permissions, .emailPreferences, .profile, .diagnostics:
            // Never on screen for more than a frame: the `.task` above hands
            // the window off the moment the step lands on `.notch`, and the
            // rest are names `current` already resolved away.
            Color.clear
        }
    }
}

/// The first word of a display name, for the one screen that greets somebody.
enum PersonName {
    static func first(of name: String) -> String? {
        let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }
}
