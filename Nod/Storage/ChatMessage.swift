import Foundation

/// One turn in a session's chat. Wire-compatible with the `chat_messages`
/// table (`20260602120200_add_chat_messages.sql`). Immutable once written.
struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let meetingID: UUID
    let userID: UUID
    /// Server-assigned via `default now()`; nil on a freshly-built row before
    /// insert — the custom encoder omits it so the DB default applies.
    let createdAt: Date?
    let role: Role
    let content: String

    enum Role: String, Codable {
        case user
        case assistant
    }

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case userID = "user_id"
        case createdAt = "created_at"
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }

    static func new(meetingID: UUID, userID: UUID, role: Role, content: String) -> ChatMessage {
        ChatMessage(id: UUID(), meetingID: meetingID, userID: userID, createdAt: nil, role: role, content: content)
    }
}
