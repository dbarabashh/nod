import SwiftUI

/// How far through the flow you are.
struct OnboardingProgress: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { each in
                Capsule(style: .continuous)
                    .fill(Theme.Palette.ink.opacity(each.position <= step.position ? 0.9 : 0.3))
                    .frame(width: each == step ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.position) of \(OnboardingStep.allCases.count)")
    }
}

#Preview {
    WelcomeBackdrop {
        VStack(spacing: 20) {
            ForEach(OnboardingStep.allCases, id: \.self) { OnboardingProgress(step: $0) }
        }
    }
    .frame(width: 320, height: 220)
}
