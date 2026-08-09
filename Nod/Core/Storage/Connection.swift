import Foundation

/// One external agent connection — a personal access token that lets the user's
/// own AI client (Claude, ChatGPT, Gemini, …) read their meetings through the
/// `connect` edge function. Wire-compatible with the `connections` table.
///
/// The raw token is never stored or returned; only its sha256 lives server-side.
/// This model is read-only (listing/revoking) — minting goes through the
/// `create_connection` RPC, which receives only the on-device hash.
struct Connection: Identifiable, Decodable {
    let id: UUID
    let name: String
    let client: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case client
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case revokedAt = "revoked_at"
    }

    var clientKind: ConnectionClient {
        ConnectionClient(rawValue: client) ?? .other
    }
}

/// Which AI client a connection targets. Purely informational on the server
/// (the token + API are identical for every client); drives the in-app picker
/// and per-provider setup instructions.
enum ConnectionClient: String, CaseIterable, Identifiable {
    case claude
    case chatgpt
    case gemini
    case other

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .gemini: "Gemini"
        case .other: "Other"
        }
    }

    /// Asset-catalog image name for the provider's brand logo. Drop the official
    /// logo into the matching imageset in `Assets.xcassets`; until then the UI
    /// falls back to `fallbackSymbol`.
    var iconAssetName: String {
        switch self {
        case .claude: "ConnClaude"
        case .chatgpt: "ConnChatGPT"
        case .gemini: "ConnGemini"
        case .other: "ConnOther"
        }
    }

    /// SF Symbol shown until the brand logo asset is supplied.
    var fallbackSymbol: String {
        switch self {
        case .claude: "nc-sparkle-3"
        case .chatgpt: "nc-msgs"
        case .gemini: "nc-sparkle-3"
        case .other: "nc-puzzle-piece"
        }
    }
}
