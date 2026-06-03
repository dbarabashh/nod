import Foundation

/// The user's always-on personal context. Wire-compatible with the
/// `profiles` table (`20260602120000_add_profiles.sql`). One row per user;
/// every field optional in the DB, surfaced here as non-optional strings
/// ("" when absent) so the editing UI can bind to them directly.
struct Profile: Codable, Equatable {
    let userID: UUID
    var displayName: String
    var role: String
    var focus: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case role
        case focus
    }

    init(userID: UUID, displayName: String = "", role: String = "", focus: String = "") {
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.focus = focus
    }

    /// Nullable text columns decode as absent or JSON `null`; coalesce both
    /// to "" so the rest of the app never juggles optionals.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        displayName = try (c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        role = try (c.decodeIfPresent(String.self, forKey: .role)) ?? ""
        focus = try (c.decodeIfPresent(String.self, forKey: .focus)) ?? ""
    }

    var isEmpty: Bool {
        displayName.trimmed.isEmpty && role.trimmed.isEmpty && focus.trimmed.isEmpty
    }

    /// The block prepended to LLM system prompts. Returns "" when nothing is
    /// filled in, so an empty profile costs zero tokens and changes nothing.
    /// Phrased as background-only to keep the transcript-grounding rules in
    /// each prompt authoritative.
    var promptBlock: String {
        guard !isEmpty else { return "" }
        var lines = ["[ABOUT THE USER — background only, never invent beyond it]"]
        if !displayName.trimmed.isEmpty { lines.append("- Name: \(displayName.trimmed)") }
        if !role.trimmed.isEmpty { lines.append("- Role: \(role.trimmed)") }
        if !focus.trimmed.isEmpty { lines.append("- Currently focused on: \(focus.trimmed)") }
        lines.append(
            "Use this only to interpret who [Me] is and what matters to them. It is NOT part of the transcript — do not attribute it as something that was said."
        )
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
