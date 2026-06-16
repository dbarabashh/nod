import Combine
import Foundation
import Supabase

/// Persists the user's acknowledgement of the recording-consent disclaimer.
///
/// Two-layer model, deliberately decoupled:
/// - `UserDefaults["consent.accepted"]` — per-device UX gate that controls
///   whether the modal shows next time. Set ONLY when the user ticks
///   "Don't show again".
/// - `public.consent_acknowledgements` row in Supabase — durable audit log
///   of every legal acknowledgement, regardless of the gate toggle. Written
///   fire-and-forget; never blocks recording.
///
/// Every click on Acknowledge writes one audit row. The "Don't show again"
/// toggle only governs the device-side UX gate.
@MainActor
final class ConsentPreference: ObservableObject {
    /// Bumped whenever the disclaimer body copy changes materially.
    /// Stored alongside each Supabase row so we can prove exactly which
    /// wording a given user agreed to. v2 (2026-05-24): dropped the
    /// Ukrainian translation; the disclaimer is now English-only and the
    /// audit row's `language_code` is always "en" to match the rendered text,
    /// independent of the user's Nod language.
    static let disclaimerVersion = "2026-05-24-v2"

    @Published private(set) var isAccepted: Bool

    private static let storageKey = "consent.accepted"

    private let supabase: SupabaseClient?
    private let auth: AuthService?
    private let defaults: UserDefaults

    init(
        supabase: SupabaseClient? = nil,
        auth: AuthService? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.supabase = supabase
        self.auth = auth
        self.defaults = defaults
        isAccepted = defaults.bool(forKey: Self.storageKey)
    }

    /// Records a legal acknowledgement. ALWAYS writes the Supabase audit row
    /// (best-effort, fire-and-forget). Optionally persists the "don't show
    /// again" UX gate when `persistGate == true`.
    func acknowledge(persistGate: Bool) {
        writeAuditRow()
        if persistGate {
            isAccepted = true
            defaults.set(true, forKey: Self.storageKey)
        }
    }

    private func writeAuditRow() {
        // Snapshot values that need MainActor isolation before crossing
        // into a detached Task. The disclaimer body is English-only, so
        // `language_code` is hard-coded to match what the user actually saw,
        // independent of their Nod language.
        let languageCode = "en"
        let appVersion = Self.appVersion()
        guard let supabase, let auth, let userID = auth.session?.user.id else {
            Log.ui.info("consent: skipping audit row (no session)")
            return
        }

        Task.detached(priority: .background) {
            await Self.logAuditRow(
                supabase: supabase,
                userID: userID,
                languageCode: languageCode,
                appVersion: appVersion
            )
        }
    }

    private static func logAuditRow(
        supabase: SupabaseClient,
        userID: UUID,
        languageCode: String,
        appVersion: String
    ) async {
        struct Row: Encodable {
            let userID: UUID
            let disclaimerVersion: String
            let languageCode: String
            let appVersion: String

            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case disclaimerVersion = "disclaimer_version"
                case languageCode = "language_code"
                case appVersion = "app_version"
            }
        }

        let row = Row(
            userID: userID,
            disclaimerVersion: disclaimerVersion,
            languageCode: languageCode,
            appVersion: appVersion
        )

        do {
            try await supabase
                .from("consent_acknowledgements")
                .insert(row)
                .execute()
            Log.ui.info("consent: audit row written")
        } catch {
            Log.ui.error("consent: audit row insert failed — \(error.localizedDescription)")
        }
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }
}
