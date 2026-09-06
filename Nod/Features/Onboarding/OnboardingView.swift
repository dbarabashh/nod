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
    @EnvironmentObject private var modeStore: ModeStore
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var consent: ConsentPreference

    /// Pad past the traffic-light strip so step titles never collide with the
    /// close button. macOS chrome occupies ~28pt of the window's top.
    private static let chromeInset: CGFloat = 48

    /// True once the profile fetch has finished — successfully or not. Gates
    /// only the profile step; every other step is independent of it.
    @State private var profileLoaded = false

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

    @ViewBuilder
    private var content: some View {
        switch state.status.currentStep {
        case .welcome where !profileLoaded:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .welcome:
            // Commit the language pick only when the user actually advances
            // past Welcome — so an exploratory tap in the picker doesn't
            // persist if they close onboarding mid-flow.
            WelcomeStep(
                strings: strings,
                firstName: PersonName.first(of: seededName),
                currentLanguage: language.current,
                onContinue: { picked in
                    language.current = picked
                    state.goNext()
                }
            )
        case .profile where !profileLoaded:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .profile:
            ProfileStep(
                initialName: seededName,
                initialPreferences: profileStore.profile?.preferences ?? "",
                initialRole: profileStore.profile?.role,
                initialHeardFrom: profileStore.profile?.heardFrom,
                onContinue: { answers in
                    if let role = answers.role { modeStore.selectPreset(for: role) }
                    telemetry.profileCompleted(role: answers.role)
                    // Fire-and-forget: the profile is a nice-to-have, never a
                    // blocker. A transient save failure just leaves the field
                    // empty (recoverable in Settings) — don't gate onboarding
                    // on the network round trip.
                    Task {
                        try? await profileStore.update {
                            $0.displayName = answers.name
                            $0.preferences = answers.preferences
                            $0.role = answers.role
                            $0.heardFrom = answers.heardFrom
                        }
                    }
                    state.goNext()
                },
                onSkip: {
                    telemetry.profileSkipped()
                    state.goNext()
                }
            )
        case .diagnostics:
            DiagnosticsChoice(analytics: analytics, consent: consent) { state.goNext() }
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notch, .calendar, .permissions, .emailPreferences:
            // Never on screen for more than a frame: the `.task` above hands
            // the window off the moment the step lands here.
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
