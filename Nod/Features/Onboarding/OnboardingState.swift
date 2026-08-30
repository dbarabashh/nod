import Combine
import Foundation

/// The flow, in order. Calendar sits second on purpose: it is the one answer
/// that changes how well everything downstream works — an invitation gives the
/// diarizer an exact speaker count and the names to go with it, and without one
/// `MeetingParticipants` falls back to a window list that counted sixteen
/// people for a four-person call.
///
/// `allCases` is the order. The raw value is a *name*, not a position, so a
/// reorder is a reorder rather than a stored-data migration — which is what the
/// 1.0–1.4 table below exists to stop happening again.
enum OnboardingStep: String, Codable, CaseIterable {
    case welcome
    case calendar
    case permissions
    case profile
    case emailPreferences

    /// Where this step sits today, for the dots and for next/previous. Read
    /// rather than stored: nothing persists it any more.
    var position: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

struct OnboardingStatus: Codable {
    static let currentVersion = "1.5"

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

        // Expand phase: 1.5 writes the name under `stepName` *and* keeps
        // writing the legacy position under `currentStep`, so a downgrade to a
        // 1.4 build still resumes on the right step. Read the name first; fall
        // back to the position table for everything written before it existed.
        if let name = try container.decodeIfPresent(String.self, forKey: .stepName),
           let step = OnboardingStep(rawValue: name) {
            currentStep = step
        } else {
            let storedPosition = try container.decodeIfPresent(Int.self, forKey: .currentStep) ?? 1
            currentStep = Self.migrateStep(storedPosition, from: storedVersion)
        }
        version = Self.currentVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(completed, forKey: .completed)
        try container.encode(permissionsSkipped, forKey: .permissionsSkipped)
        try container.encode(calendarPrompted, forKey: .calendarPrompted)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(currentStep.rawValue, forKey: .stepName)
        // The legacy field, still written for a build that only knows it.
        // Retired once no supported build reads it — see the cleanup issue.
        try container.encode(currentStep.position, forKey: .currentStep)
    }

    private enum CodingKeys: String, CodingKey {
        case version, completed, currentStep, stepName, permissionsSkipped, calendarPrompted, lastUpdated
    }

    /// Every position-based order Nod ever shipped. Terminal: nothing writes a
    /// position as the source of truth any more, so this table stops growing.
    ///
    /// The tutorial is gone; whoever stood on it had already granted
    /// permissions and filled the profile, so 1.3's slot 4 resolves to the
    /// calendar — the one thing that flow had not yet asked them for.
    private static let ordersByVersion: [String: [OnboardingStep]] = [
        "1.0": [.welcome, .permissions, .calendar, .emailPreferences],
        "1.1": [.welcome, .profile, .permissions, .calendar, .emailPreferences],
        "1.2": [.welcome, .profile, .permissions, .calendar, .emailPreferences],
        "1.3": [.welcome, .profile, .permissions, .calendar, .calendar, .emailPreferences],
        "1.4": [.welcome, .calendar, .permissions, .profile, .emailPreferences]
    ]

    /// An unknown version is one this build has never shipped — a downgrade, or
    /// a file somebody edited. The newest order is the best guess available, and
    /// starting over is the safe fallback.
    private static func migrateStep(_ position: Int, from version: String) -> OnboardingStep {
        let order = ordersByVersion[version] ?? OnboardingStep.allCases
        guard order.indices.contains(position - 1) else { return .welcome }
        return order[position - 1]
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
        move(by: 1)
    }

    func goPrevious() {
        move(by: -1)
    }

    /// Steps by index in `allCases`, not by raw value: the raw value is a name
    /// now, and the order lives in one place so the dots and the navigation can
    /// never disagree about it.
    private func move(by offset: Int) {
        let steps = OnboardingStep.allCases
        guard let current = steps.firstIndex(of: status.currentStep) else { return }
        let next = steps.index(current, offsetBy: offset)
        guard steps.indices.contains(next) else { return }
        status.currentStep = steps[next]
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
        // Someone who walked the flow has already been asked, at step 2. Without
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
