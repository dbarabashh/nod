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
    /// What the user does. Drives the starting meeting mode and segments the
    /// funnel — and stays out of `promptBlock` on purpose, since that is
    /// exactly the role-shaped prompt line removed above.
    var role: WorkRole?
    /// Where they first heard about Nod. Attribution only; nothing reads it at
    /// runtime.
    var heardFrom: AcquisitionSource?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case preferences
        case role
        case heardFrom = "heard_from"
    }

    init(
        userID: UUID,
        displayName: String = "",
        preferences: String = "",
        role: WorkRole? = nil,
        heardFrom: AcquisitionSource? = nil
    ) {
        self.userID = userID
        self.displayName = displayName
        self.preferences = preferences
        self.role = role
        self.heardFrom = heardFrom
    }

    /// Nullable text columns decode as absent or JSON `null`; coalesce both
    /// to "" so the rest of the app never juggles optionals. A role or channel
    /// this build doesn't know (row written by a newer client) reads as nil
    /// rather than failing the whole profile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        displayName = try (c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        preferences = try (c.decodeIfPresent(String.self, forKey: .preferences)) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role).flatMap(WorkRole.init(rawValue:))
        heardFrom = try c.decodeIfPresent(String.self, forKey: .heardFrom).flatMap(AcquisitionSource.init(rawValue:))
    }

    var isEmpty: Bool {
        displayName.trimmed.isEmpty && preferences.trimmed.isEmpty
    }

    /// The block prepended to LLM system prompts. Returns "" when nothing is
    /// filled in, so an empty profile costs zero tokens and changes nothing.
    /// Phrased as background-only to keep the transcript-grounding rules in
    /// each prompt authoritative.
    ///
    /// It says who is asking and deliberately not who `[Me]` is: on a session
    /// somebody shared, `[Me]` is the person who recorded it. Which voice the
    /// tag belongs to is known where the session is, so it is stated there, by
    /// the prompts that hold a transcript.
    var promptBlock: String {
        guard !isEmpty else { return "" }
        var lines = ["[WHO IS ASKING — background only, never invent beyond it]"]
        if !displayName.trimmed.isEmpty { lines.append("- Name: \(displayName.trimmed)") }
        if !preferences.trimmed.isEmpty { lines.append("- What they want Nod to focus on: \(preferences.trimmed)") }
        lines.append(
            "Use this to shape what you emphasise. It is NOT part of the transcript — do not attribute it as something that was said, and do not assume this person is a voice in the recording."
        )
        return lines.joined(separator: "\n")
    }
}

/// What the user does, asked once during onboarding. Kept short on purpose —
/// a list long enough to be exhaustive is a list nobody reads to the end of.
enum WorkRole: String, Codable, CaseIterable, Identifiable {
    case founder
    case recruiter
    case sales
    case manager
    case engineer
    case consultant
    case other

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .founder: "Founder"
        case .recruiter: "Recruiter / HR"
        case .sales: "Sales"
        case .manager: "Manager"
        case .engineer: "Engineer"
        case .consultant: "Consultant"
        case .other: "Something else"
        }
    }
}

/// Where the user first heard about Nod. We have no attribution at all today,
/// so every answer is signal we currently don't have.
enum AcquisitionSource: String, Codable, CaseIterable, Identifiable {
    case friend
    case search
    case twitter
    case linkedin
    case youtube
    case reddit
    case productHunt = "product_hunt"
    case other

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .friend: "Friend or colleague"
        case .search: "Search engine"
        case .twitter: "X (Twitter)"
        case .linkedin: "LinkedIn"
        case .youtube: "YouTube"
        case .reddit: "Reddit"
        case .productHunt: "Product Hunt"
        case .other: "Somewhere else"
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Profile {
    /// First name only, or nil. Two surfaces address the user by name — the
    /// chat's opener and the notch card for a meeting that is starting — and a
    /// full name reads like a form letter in both.
    var firstName: String? {
        Self.firstName(in: displayName)
    }

    static func firstName(in displayName: String?) -> String? {
        displayName?.trimmed.split(separator: " ").first.map(String.init)
    }
}
