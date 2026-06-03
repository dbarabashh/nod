import Combine
import Foundation
import Supabase

/// Supabase-backed store for the signed-in user's `Profile`.
///
/// Loaded once after sign-in so `promptContext` is ready before the first
/// meeting ends; written via upsert from onboarding and the Settings editor.
/// RLS (`auth.uid() = user_id`) scopes every read/write to the owner.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: Profile?

    private let supabase: SupabaseClient
    private let auth: AuthService
    private static let tableName = "profiles"

    init(supabase: SupabaseClient, auth: AuthService) {
        self.supabase = supabase
        self.auth = auth
    }

    /// The block injected into LLM system prompts. Empty string when there's
    /// no profile or it's blank — callers prepend it unconditionally.
    var promptContext: String {
        profile?.promptBlock ?? ""
    }

    /// Fetches the current user's row. No-op if the cache is already
    /// populated for the signed-in user. Failures are logged, not surfaced —
    /// a missing profile just means no extra context, never a blocked flow.
    func load(force: Bool = false) async {
        guard let userID = auth.currentSupabaseSession?.user.id else { return }
        if !force, profile?.userID == userID { return }
        do {
            let rows: [Profile] = try await supabase
                .from(Self.tableName)
                .select()
                .eq("user_id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value
            profile = rows.first ?? Profile(userID: userID)
        } catch {
            Log.ui.error("ProfileStore.load failed: \(error.localizedDescription)")
        }
    }

    /// Upserts the three editable fields for the signed-in user. Throws on
    /// network / RLS error so the caller can surface a retry affordance.
    func save(displayName: String, role: String, focus: String) async throws {
        guard let userID = auth.currentSupabaseSession?.user.id else {
            throw ProfileError.notSignedIn
        }
        Log.ui.info("ProfileStore.save user=\(userID.uuidString)")

        struct Upsert: Encodable {
            let user_id: UUID
            let display_name: String
            let role: String
            let focus: String
            let updated_at: Date
        }
        let payload = Upsert(
            user_id: userID,
            display_name: displayName.trimmedOrEmpty,
            role: role.trimmedOrEmpty,
            focus: focus.trimmedOrEmpty,
            updated_at: Date()
        )
        try await supabase
            .from(Self.tableName)
            .upsert(payload, onConflict: "user_id")
            .execute()

        profile = Profile(
            userID: userID,
            displayName: payload.display_name,
            role: payload.role,
            focus: payload.focus
        )
    }

    /// Drops the cached profile on sign-out so the next user can't inherit
    /// the previous one's context through an LLM prompt.
    func clear() {
        profile = nil
    }

    enum ProfileError: LocalizedError {
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "You're signed out — sign in to save your profile."
            }
        }
    }
}

private extension String {
    var trimmedOrEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension User {
    /// Best display name from the OAuth identity metadata, "" if none.
    /// Used to pre-fill the onboarding profile name and the status-bar menu.
    var profileDisplayName: String {
        for key in ["full_name", "name", "user_name"] {
            if let value = userMetadata[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return ""
    }
}
