import Foundation

/// The user's always-on personal context. Wire-compatible with the
/// `profiles` table (`20260602120000_add_profiles.sql`). One row per user;
/// every field optional in the DB, surfaced here as non-optional strings
/// ("" when absent) so the editing UI can bind to them directly.
struct Profile: Codable, Equatable {
    let userID: UUID
    var displayName: String
    /// How the user wants Nod to work for them — durable, cross-context (e.g.
    /// "pull out what I committed to, keep summaries short"). Replaces the old
    /// role/focus fields, which were work-specific and wrong for the many
    /// non-work sessions (therapy, side projects) a global profile also feeds.
    var preferences: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case preferences
    }

    init(userID: UUID, displayName: String = "", preferences: String = "") {
        self.userID = userID
        self.displayName = displayName
        self.preferences = preferences
    }

    /// Nullable text columns decode as absent or JSON `null`; coalesce both
    /// to "" so the rest of the app never juggles optionals.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        displayName = try (c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        preferences = try (c.decodeIfPresent(String.self, forKey: .preferences)) ?? ""
    }

    var isEmpty: Bool {
        displayName.trimmed.isEmpty && preferences.trimmed.isEmpty
    }

    /// The block prepended to LLM system prompts. Returns "" when nothing is
    /// filled in, so an empty profile costs zero tokens and changes nothing.
    /// Phrased as background-only to keep the transcript-grounding rules in
    /// each prompt authoritative.
    var promptBlock: String {
        guard !isEmpty else { return "" }
        var lines = ["[ABOUT THE USER — background only, never invent beyond it]"]
        if !displayName.trimmed.isEmpty { lines.append("- Name: \(displayName.trimmed)") }
        if !preferences.trimmed.isEmpty { lines.append("- What they want Nod to focus on: \(preferences.trimmed)") }
        lines.append(
            "Use this to interpret who [Me] is and to shape what you emphasise. It is NOT part of the transcript — do not attribute it as something that was said."
        )
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
