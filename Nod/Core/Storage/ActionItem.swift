import Foundation

/// One outstanding task extracted from a meeting's recap. Wire-compatible with
/// the `action_items` table (`20260629120000_action_items.sql`). Promoted out
/// of the recap markdown so it can carry a persistent `done` state, be
/// aggregated across meetings, and (later) be deduped.
///
/// Single-user product: there is no owner/assignee column — every item is the
/// user's own task; an "ask Sam" lives inside `text`. `done`/`doneAt` are the
/// only mutable fields (toggled via `ActionItemStore.setDone`); everything else
/// is set once at extraction time. `createdAt`/`updatedAt`/`deletedAt` are
/// server-driven and nil on a freshly-built row before insert.
struct ActionItem: Codable, Identifiable, Equatable {
    let id: UUID
    let meetingID: UUID
    let userID: UUID
    let text: String
    /// Free-text deadline as stated in the meeting ("by Friday"), or nil.
    let deadline: String?
    /// Preserves the recap's emitted order within a meeting.
    let position: Int
    let done: Bool
    let doneAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    /// Still outstanding: not ticked off, not in the trash. Both halves matter
    /// — the notch card and the Home count read the same data and used to
    /// disagree about the second one.
    var isOpen: Bool {
        !done && deletedAt == nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case userID = "user_id"
        case text
        case deadline
        case position
        case done
        case doneAt = "done_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// Insert payload — server-driven timestamps are omitted so the DB defaults
    /// apply; `done_at` is only sent once the item is checked off (via a patch).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(userID, forKey: .userID)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encode(position, forKey: .position)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
    }

    static func new(meetingID: UUID, userID: UUID, text: String, deadline: String?, position: Int) -> ActionItem {
        ActionItem(
            id: UUID(),
            meetingID: meetingID,
            userID: userID,
            text: text,
            deadline: deadline,
            position: position,
            done: false,
            doneAt: nil,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
    }

    /// A copy with new text — backs the inline rename's optimistic update
    /// before `ActionItemStore.updateText` persists it.
    func renamed(_ newText: String) -> ActionItem {
        ActionItem(
            id: id,
            meetingID: meetingID,
            userID: userID,
            text: newText,
            deadline: deadline,
            position: position,
            done: done,
            doneAt: doneAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    /// A copy with the done state flipped — used for the optimistic local
    /// update before `ActionItemStore.setDone` persists it.
    func marked(done: Bool, at date: Date?) -> ActionItem {
        ActionItem(
            id: id,
            meetingID: meetingID,
            userID: userID,
            text: text,
            deadline: deadline,
            position: position,
            done: done,
            doneAt: done ? date : nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
