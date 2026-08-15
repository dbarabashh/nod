import Combine
import Foundation

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 1
    case profile = 2
    case permissions = 3
    case tutorial = 4
    case calendar = 5
    case emailPreferences = 6
}

struct OnboardingStatus: Codable {
    static let currentVersion = "1.3"

    var version: String = currentVersion
    var completed: Bool = false
    var currentStep: OnboardingStep = .welcome
    var permissionsSkipped: Bool = false
    /// Whether this Mac has put the calendar question to someone who finished
    /// onboarding before the step existed. Answering it either way sets this —
    /// the point is that it is asked once, not that it is accepted.
    var calendarPrompted: Bool = false
    var lastUpdated: Date = .init()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        permissionsSkipped = try container.decodeIfPresent(Bool.self, forKey: .permissionsSkipped) ?? false
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .init()
        // Absent for everyone who onboarded before 1.3, which is the whole
        // population this flag exists to reach — so its default has to be false
        // rather than "assume they have seen it".
        calendarPrompted = try container.decodeIfPresent(Bool.self, forKey: .calendarPrompted) ?? false

        let storedStep = try container.decodeIfPresent(Int.self, forKey: .currentStep) ?? OnboardingStep.welcome.rawValue
        currentStep = Self.migrateStep(storedStep, from: storedVersion)
        version = Self.currentVersion
    }

    /// Every insertion into the flow shifts the raw values at or above it, so a
    /// step persisted by an older build has to be shifted the same way before it
    /// names the step the user was actually on. Profile arrived at 2 in 1.1,
    /// calendar at 5 in 1.3.
    private static func migrateStep(_ rawValue: Int, from version: String) -> OnboardingStep {
        var raw = rawValue
        if version == "1.0", raw >= 2 { raw += 1 }
        if ["1.0", "1.1", "1.2"].contains(version), raw >= 5 { raw += 1 }
        return OnboardingStep(rawValue: raw) ?? .welcome
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

    /// The step alone cannot reach anyone who already finished onboarding —
    /// `completed` is true, so the flow never runs again.
    var needsCalendarPrompt: Bool {
        status.completed && !status.calendarPrompted
    }

    func markCalendarPrompted() {
        guard !status.calendarPrompted else { return }
        status.calendarPrompted = true
        save()
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
        // Someone who walked the flow has already been asked, at step 5. Without
        // this they would finish onboarding and be handed the same question
        // again as a standalone window.
        status.calendarPrompted = true
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
