import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var state: OnboardingState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var language: LanguagePreference

    /// Pad past the traffic-light strip so step titles never collide with the
    /// close button. macOS chrome occupies ~28pt of the window's top.
    private static let chromeInset: CGFloat = 36

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            content
                .padding(.top, Self.chromeInset)
        }
        .frame(width: 580, height: 540)
        .onAppear { permissions.refresh() }
    }

    private var strings: OnboardingStrings {
        OnboardingStrings.forLanguageCode(language.current.whisperCode)
    }

    @ViewBuilder
    private var content: some View {
        switch state.status.currentStep {
        case .welcome:
            WelcomeStep(strings: strings, onContinue: state.goNext)
        case .permissions:
            PermissionsStep(
                strings: strings,
                onFinish: { skipped in
                    state.recordPermissionsDecision(skipped: skipped)
                    if skipped {
                        // Skipping permissions means the user opted out of the
                        // feature the tutorial walks through — finish onboarding
                        // straight away rather than narrating features they
                        // declined.
                        state.complete()
                        onComplete()
                    } else {
                        state.goNext()
                    }
                }
            )
        case .tutorial:
            TutorialStep(strings: strings, onFinish: {
                state.complete()
                onComplete()
            })
        }
    }
}

/// Calmer than `AuroraBackground` — a near-black base with a single soft
/// bloom in the corner. Premium Mac apps go quiet; the aurora reads as
/// "marketing splash."
private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()

            Circle()
                .fill(Theme.Palette.violet)
                .frame(width: 480, height: 480)
                .blur(radius: 160)
                .opacity(0.18)
                .offset(x: -140, y: -200)

            Circle()
                .fill(Theme.Palette.cyan)
                .frame(width: 360, height: 360)
                .blur(radius: 160)
                .opacity(0.10)
                .offset(x: 180, y: 220)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
