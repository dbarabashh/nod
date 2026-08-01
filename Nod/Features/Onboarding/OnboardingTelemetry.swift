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

    /// `step_shown` is deduplicated per process, not per step transition —
    /// SwiftUI re-runs `.task(id:)` on window rebuilds. A relaunch (which the
    /// Screen Recording grant forces) is a new process and logs the step again,
    /// which is exactly the signal we want to see.
    private var loggedSteps: Set<OnboardingStep> = []

    init(supabase: SupabaseClient? = nil, auth: AuthService? = nil) {
        self.supabase = supabase
        self.auth = auth
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
        guard let row = makeRow(.relaunchClicked, step: .permissions) else { return }
        await write(row)
    }

    func relaunchFailed(_ reason: String) {
        log(.relaunchFailed, step: .permissions, detail: reason)
    }

    func completed() {
        log(.completed)
    }

    private func log(_ event: Event, step: OnboardingStep? = nil, detail: String? = nil) {
        guard let row = makeRow(event, step: step, detail: detail) else { return }
        Task.detached(priority: .background) { [weak self] in
            await self?.write(row)
        }
    }

    private func makeRow(_ event: Event, step: OnboardingStep? = nil, detail: String? = nil) -> OnboardingEventRow? {
        guard let userID = auth?.session?.user.id else { return nil }
        return OnboardingEventRow(
            userID: userID,
            event: event.rawValue,
            step: step.map(Self.name(for:)),
            detail: detail,
            appVersion: Self.appVersion()
        )
    }

    private func write(_ row: OnboardingEventRow) async {
        guard let supabase else { return }
        do {
            try await supabase
                .from("onboarding_events")
                .insert(row)
                .execute()
        } catch {
            Log.ui.error("onboarding telemetry insert failed — \(error.localizedDescription)")
        }
    }

    private static func name(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: "welcome"
        case .profile: "profile"
        case .permissions: "permissions"
        case .tutorial: "tutorial"
        }
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }
}

private struct OnboardingEventRow: Encodable {
    let userID: UUID
    let event: String
    let step: String?
    let detail: String?
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case event
        case step
        case detail
        case appVersion = "app_version"
    }
}
