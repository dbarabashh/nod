import Combine
import Foundation
import Supabase

/// Records the user's progress through onboarding into `onboarding_events`.
///
/// Onboarding state is persisted to UserDefaults only, so without this the
/// steps between sign-in and the first recording produce no server-side signal
/// — see the migration for what that cost us. Writes are fire-and-forget on a
/// detached task: a step transition must never wait on, or fail because of,
/// telemetry.
@MainActor
final class OnboardingTelemetry: ObservableObject {
    enum Event: String {
        case stepShown = "step_shown"
        case profileCompleted = "profile_completed"
        case profileSkipped = "profile_skipped"
        case permissionRequested = "permission_requested"
        case permissionGranted = "permission_granted"
        case permissionDenied = "permission_denied"
        case permissionPendingRelaunch = "permission_pending_relaunch"
        case permissionsSkipped = "permissions_skipped"
        case relaunchPrompted = "relaunch_prompted"
        case relaunchClicked = "relaunch_clicked"
        case relaunchFailed = "relaunch_failed"
        case completed = "onboarding_completed"
    }

    enum Permission: String {
        case microphone
        case screenRecording = "screen_recording"
    }

    private let supabase: SupabaseClient?
    private let auth: AuthService?
    private let analytics: ProductAnalytics
    private let defaults: UserDefaults
    private let installationID: UUID
    private let appSessionID = UUID()
    private var queue: [QueuedOnboardingEvent]
    private var isFlushing = false

    /// `step_shown` is deduplicated per process, not per step transition —
    /// SwiftUI re-runs `.task(id:)` on window rebuilds. A relaunch (which the
    /// Screen Recording grant forces) is a new process and logs the step again,
    /// which is exactly the signal we want to see.
    private var loggedSteps: Set<OnboardingStep> = []

    init(
        supabase: SupabaseClient? = nil,
        auth: AuthService? = nil,
        analytics: ProductAnalytics,
        defaults: UserDefaults = .standard
    ) {
        self.supabase = supabase
        self.auth = auth
        self.analytics = analytics
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.queueKey),
           let stored = try? JSONDecoder().decode([QueuedOnboardingEvent].self, from: data) {
            queue = stored
        } else {
            queue = []
        }
        if let stored = defaults.string(forKey: Self.installationKey),
           let id = UUID(uuidString: stored) {
            installationID = id
        } else {
            let id = UUID()
            installationID = id
            defaults.set(id.uuidString, forKey: Self.installationKey)
        }
        analytics.onOptOut { [weak self] in self?.discardQueuedEvents() }
    }

    func stepShown(_ step: OnboardingStep) {
        guard loggedSteps.insert(step).inserted else { return }
        log(.stepShown, step: step)
    }

    /// `detail` carries the role, so the funnel answers "who signs up" and
    /// "who finishes" in one query. Nil when they answered without picking one.
    func profileCompleted(role: WorkRole?) {
        log(.profileCompleted, step: .profile, detail: role?.rawValue)
    }

    func profileSkipped() {
        log(.profileSkipped, step: .profile)
    }

    func permissionRequested(_ permission: Permission) {
        log(.permissionRequested, step: .permissions, detail: permission.rawValue)
    }

    func permissionResolved(_ permission: Permission, granted: Bool) {
        log(granted ? .permissionGranted : .permissionDenied, step: .permissions, detail: permission.rawValue)
    }

    /// Screen Recording only: the answer can't be read back before a restart,
    /// so this replaces the `permission_denied` we used to log on faith. Every
    /// such row was a guess, and the funnel read 0 grants while users were
    /// recording system audio fine.
    func screenRecordingPendingRelaunch() {
        log(.permissionPendingRelaunch, step: .permissions, detail: Permission.screenRecording.rawValue)
    }

    func permissionsSkipped() {
        log(.permissionsSkipped, step: .permissions)
    }

    func relaunchPrompted() {
        log(.relaunchPrompted, step: .permissions)
    }

    /// Awaits the write, unlike every other event: the caller terminates the
    /// process immediately afterwards, and a detached task would lose the row.
    func relaunchClicked() async {
        guard let queued = makeQueuedEvent(.relaunchClicked, step: .permissions) else { return }
        queue.append(queued)
        persistQueue()
        await flush()
    }

    func relaunchFailed(_ reason: String) {
        log(.relaunchFailed, step: .permissions, detail: reason)
    }

    func completed() {
        log(.completed)
    }

    private func log(_ event: Event, step: OnboardingStep? = nil, detail: String? = nil) {
        guard let queued = makeQueuedEvent(event, step: step, detail: detail) else { return }
        queue.append(queued)
        persistQueue()
        Task { await flush() }
    }

    private func makeQueuedEvent(
        _ event: Event,
        step: OnboardingStep? = nil,
        detail: String? = nil
    ) -> QueuedOnboardingEvent? {
        guard !analytics.isOptedOut, let userID = auth?.session?.user.id else { return nil }
        return QueuedOnboardingEvent(
            userID: userID,
            row: OnboardingEventRow(
                id: UUID(),
                occurredAt: ISO8601DateFormatter().string(from: Date()),
                appSessionID: appSessionID,
                event: event.rawValue,
                platform: "macos",
                appVersion: Self.appVersion(),
                properties: OnboardingEventProperties(
                    stage: step.map(Self.name(for:)),
                    permission: Self.permission(for: event, detail: detail),
                    reasonCode: Self.reasonCode(for: event),
                    outcome: Self.outcome(for: event)
                )
            )
        )
    }

    func flush() async {
        guard !analytics.isOptedOut,
              !isFlushing,
              let supabase,
              let userID = auth?.session?.user.id
        else { return }
        let batch = Array(queue.filter { $0.userID == userID }.prefix(25))
        guard !batch.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            try await supabase
                .rpc(
                    "record_onboarding_events",
                    params: OnboardingEventParams(
                        installationID: installationID,
                        events: batch.map(\.row)
                    )
                )
                .execute()
            let sent = Set(batch.map(\.row.id))
            queue.removeAll { sent.contains($0.row.id) }
            persistQueue()
            if queue.contains(where: { $0.userID == userID }) {
                Task { await flush() }
            }
        } catch {
            Log.ui.error("onboarding telemetry insert failed — \(error.localizedDescription)")
        }
    }

    private func discardQueuedEvents() {
        queue.removeAll()
        loggedSteps.removeAll()
        persistQueue()
        Log.ui.info("onboarding analytics opted out — queue discarded")
    }

    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: Self.queueKey)
    }

    private static func name(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: "welcome"
        case .profile: "profile"
        case .permissions: "permissions"
        case .tutorial: "tutorial"
        case .emailPreferences: "consent"
        }
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }

    private static func outcome(for event: Event) -> String? {
        switch event {
        case .stepShown: "viewed"
        case .permissionGranted: "granted"
        case .permissionDenied: "declined"
        case .relaunchFailed: "failure"
        case .completed, .profileCompleted, .profileSkipped, .permissionRequested,
             .permissionPendingRelaunch, .permissionsSkipped, .relaunchPrompted,
             .relaunchClicked: "success"
        }
    }

    private static func permission(for event: Event, detail: String?) -> String? {
        switch event {
        case .permissionRequested, .permissionGranted, .permissionDenied, .permissionPendingRelaunch:
            detail
        default:
            nil
        }
    }

    private static func reasonCode(for event: Event) -> String? {
        return switch event {
        case .permissionDenied: "permission_denied"
        case .relaunchFailed: "unknown"
        default: nil
        }
    }

    private static let installationKey = "analytics.installation-id.v1"
    private static let queueKey = "analytics.onboarding-events.queue.v1"
}

private struct QueuedOnboardingEvent: Codable {
    let userID: UUID
    let row: OnboardingEventRow
}

private struct OnboardingEventRow: Codable {
    let id: UUID
    let occurredAt: String
    let appSessionID: UUID
    let event: String
    let platform: String
    let appVersion: String
    let properties: OnboardingEventProperties

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case appSessionID = "app_session_id"
        case event
        case platform
        case appVersion = "app_version"
        case properties
    }
}

private struct OnboardingEventProperties: Codable {
    let stage: String?
    let permission: String?
    let reasonCode: String?
    let outcome: String?

    enum CodingKeys: String, CodingKey {
        case stage
        case permission
        case reasonCode = "reason_code"
        case outcome
    }
}

private struct OnboardingEventParams: Encodable {
    let installationID: UUID
    let events: [OnboardingEventRow]

    enum CodingKeys: String, CodingKey {
        case installationID = "p_installation_id"
        case events = "p_events"
    }
}
