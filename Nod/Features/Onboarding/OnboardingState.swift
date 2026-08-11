import Combine
import Foundation

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 1
    case profile = 2
    case permissions = 3
    case tutorial = 4
    case emailPreferences = 5
}

struct OnboardingStatus: Codable {
    static let currentVersion = "1.2"

    var version: String = currentVersion
    var completed: Bool = false
    var currentStep: OnboardingStep = .welcome
    var permissionsSkipped: Bool = false
    var lastUpdated: Date = .init()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        permissionsSkipped = try container.decodeIfPresent(Bool.self, forKey: .permissionsSkipped) ?? false
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .init()

        let storedStep = try container.decodeIfPresent(Int.self, forKey: .currentStep) ?? OnboardingStep.welcome.rawValue
        currentStep = Self.migrateStep(storedStep, from: storedVersion)
        version = Self.currentVersion
    }

    /// Pre-1.1 the order was welcome(1)/permissions(2)/tutorial(3) with no
    /// profile step. 1.1 inserted profile at 2, shifting permissions→3 and
    /// tutorial→4. Remap a persisted pre-1.1 raw value so a user mid-onboarding
    /// resumes at the same logical step instead of being silently sent back one.
    private static func migrateStep(_ rawValue: Int, from version: String) -> OnboardingStep {
        guard version == "1.0" else {
            return OnboardingStep(rawValue: rawValue) ?? .welcome
        }
        switch rawValue {
        case 2: return .permissions
        case 3: return .tutorial
        default: return .welcome
        }
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published private(set) var status: OnboardingStatus

    private static let storageKey = "onboarding-status"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(OnboardingStatus.self, from: data) {
            status = decoded
        } else {
            status = OnboardingStatus()
        }
    }

    var isCompleted: Bool {
        status.completed
    }

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

    #if DEBUG
        /// Clears the persisted first-run flag so the next launch replays
        /// onboarding. Local only — no account or meeting data is touched.
        static func resetPersistedStatus() {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    #endif

    private func save() {
        status.lastUpdated = Date()
        guard let data = try? JSONEncoder().encode(status) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
