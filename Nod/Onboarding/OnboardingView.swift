import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var state: OnboardingState
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        ZStack {
            AuroraBackground()
            content
        }
        .frame(width: 520, height: 420)
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch state.status.currentStep {
        case .welcome:
            WelcomeStep(onContinue: state.goNext)
        case .permissions:
            PermissionsStep(onFinish: { skipped in
                state.complete(skipped: skipped)
                onComplete()
            })
        }
    }
}
