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
    @EnvironmentObject private var calendar: CalendarService

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

    /// The steps this Mac has already answered.
    ///
    /// Derived here rather than held on `OnboardingState`: the answer lives in
    /// `PermissionManager` and `CalendarService`, and read at the moment of
    /// advancing it cannot be stale — a copy kept on the state would go wrong
    /// exactly when somebody grants a permission mid-flow.
    ///
    /// Only these two. Both are machine-level facts a second account inherits
    /// honestly: macOS grants the microphone to the app, not to an account, and
    /// this Mac's calendar is this Mac's. Welcome, profile and email consent
    /// are the person's own answers and are always asked.
    private var satisfied: Set<OnboardingStep> {
        var done: Set<OnboardingStep> = []
        if permissions.canCaptureBothSides { done.insert(.permissions) }
        if CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations) {
            done.insert(.calendar)
        }
        return done
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
                    state.goNext(skipping: satisfied)
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
                    state.goNext(skipping: satisfied)
                },
                onSkip: {
                    telemetry.profileSkipped()
                    state.goNext(skipping: satisfied)
                }
            )
        case .permissions:
            PermissionsStep(
                strings: strings,
                onFinish: { skipped in
                    state.recordPermissionsDecision(skipped: skipped)
                    if skipped { telemetry.permissionsSkipped() }
                    state.goNext(skipping: satisfied)
                }
            )
        case .calendar:
            CalendarStep(calendar: calendar, integrations: integrations, onFinish: { state.goNext(skipping: satisfied) })
        case .emailPreferences:
            EmailConsentStep(preferences: emailPreferences, onFinish: {
                telemetry.completed()
                state.complete()
                onComplete()
            })
        }
    }
}
