import Foundation
import Combine

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 1
    case permissions = 2
    case tutorial = 3
}

struct OnboardingStatus: Codable {
    var version: String = "1.0"
    var completed: Bool = false
    var currentStep: OnboardingStep = .welcome
    var permissionsSkipped: Bool = false
    var lastUpdated: Date = .init()
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published private(set) var status: OnboardingStatus

    private static let storageKey = "onboarding-status"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(OnboardingStatus.self, from: data) {
            self.status = decoded
        } else {
            self.status = OnboardingStatus()
        }
    }

    var isCompleted: Bool { status.completed }

    func goNext() {
        let next = status.currentStep.rawValue + 1
        guard let step = OnboardingStep(rawValue: next) else { return }
        status.currentStep = step
        save()
    }

    func goPrevious() {
        let prev = status.currentStep.rawValue - 1
        guard let step = OnboardingStep(rawValue: prev) else { return }
        status.currentStep = step
        save()
    }

    /// Symmetric write so the field reflects the user's most recent choice
    /// (mirroring the prior `complete(skipped:)` semantics).
    func recordPermissionsDecision(skipped: Bool) {
        status.permissionsSkipped = skipped
        save()
    }

    func complete() {
        status.completed = true
        save()
    }

    func reset() {
        status = OnboardingStatus()
        save()
    }

    private func save() {
        status.lastUpdated = Date()
        guard let data = try? JSONEncoder().encode(status) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
