import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var state: OnboardingState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var language: LanguagePreference
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var telemetry: OnboardingTelemetry
    @EnvironmentObject private var modeStore: ModeStore
    @EnvironmentObject private var emailPreferences: EmailPreferenceService
    @EnvironmentObject private var integrations: IntegrationService

    /// Pad past the traffic-light strip so step titles never collide with the
    /// close button. macOS chrome occupies ~28pt of the window's top.
    private static let chromeInset: CGFloat = 48

    /// True once the profile fetch has finished — successfully or not. Gates
    /// only the profile step; every other step is independent of it.
    @State private var profileLoaded = false

    var body: some View {
        ZStack {
            Image("WelcomeSky")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Reserve the traffic-light strip as a sibling so it subtracts
                // from the content height instead of overflowing a full-height
                // step (which clipped the bottom buttons).
                Color.clear.frame(height: Self.chromeInset)
                content
            }
            .environment(\.colorScheme, .light)
        }
        // minWidth/minHeight (not fixed) so when users with large system
        // text scaling grow the window, the SwiftUI content actually
        // expands to use the new space.
        .frame(minWidth: 580, minHeight: 560)
        .onAppear { permissions.refresh() }
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
        .task(id: state.status.currentStep) { telemetry.stepShown(state.status.currentStep) }
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
        case .welcome:
            // Commit the language pick only when the user actually advances
            // past Welcome — so an exploratory tap in the picker doesn't
            // persist if they close onboarding mid-flow.
            WelcomeStep(
                strings: strings,
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
        case .permissions:
            PermissionsStep(
                strings: strings,
                onFinish: { skipped in
                    state.recordPermissionsDecision(skipped: skipped)
                    // Skipping permissions used to end onboarding on the spot.
                    // The tutorial is where the panel, the hotkey and the recap
                    // are explained — the person who skipped needs it most, and
                    // they left with no idea where the app lives.
                    if skipped { telemetry.permissionsSkipped() }
                    state.goNext()
                }
            )
        case .tutorial:
            TutorialStep(strings: strings, onFinish: {
                state.goNext()
            })
        case .calendar:
            CalendarStep(integrations: integrations, onFinish: { state.goNext() })
        case .emailPreferences:
            EmailConsentStep(preferences: emailPreferences, onFinish: {
                telemetry.completed()
                state.complete()
                onComplete()
            })
        }
    }
}
