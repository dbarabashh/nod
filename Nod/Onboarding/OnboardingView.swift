import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var state: OnboardingState
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.22),
                    Color(red: 0.04, green: 0.06, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

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
