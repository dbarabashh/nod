import Foundation

/// One thing a meeting produced — a task, a decision, an open question. Wire
/// compatible with the `action_items` table (`20260629120000_action_items.sql`,
/// widened by `20260806164035_action_item_lifecycle.sql`).
///
/// It is no longer only the recap's output. A row can be raised mid-meeting,
/// corroborated or dropped when the recap lands, and superseded by a later
/// moment in the same conversation — which is why `status` exists alongside
/// `done`. `done` is the user's checkbox on a real task; `status` is whether it
/// is a real task at all yet.
///
/// Single-user product: there is no owner/assignee column — every item is the
/// user's own task; an "ask Sam" lives inside `text`. `createdAt`/`updatedAt`/
/// `deletedAt` are server-driven and nil on a freshly-built row before insert.
struct ActionItem: Codable, Identifiable, Equatable {
    let id: UUID
    let meetingID: UUID
    let userID: UUID
    var text: String
    /// Free-text deadline as stated in the meeting ("by Friday"), or nil.
    let deadline: String?
    /// What kind of thing a meeting produced. Tasks are the majority and the
    /// only kind the recap has ever emitted; the rest come from the live pass,
    /// which hears decisions and open questions too.
    var kind: Kind = .action
    /// Where in its life this is — orthogonal to `done`, which is the user's
    /// checkbox on a real task. This is whether it is a real task *yet*.
    var status: Status = .confirmed
    /// Which pass produced it, so the finalize can reconcile rather than
    /// refusing to write because rows already exist.
    var source: Source = .recap
    /// What this replaces, when a later moment in the same meeting overruled an
    /// earlier one. The replacement points back; the replaced row is marked
    /// `superseded` rather than rewritten, because rewriting loses the history
    /// that is the whole point of noticing.
    var revisionOf: UUID?
    /// The transcript entry that produced this (`meeting_transcripts.idx`).
    /// The answer to "why does this exist, and who said it".
    var evidenceIdx: Int?
    /// Preserves the recap's emitted order within a meeting. Nil for anything
    /// the live pass appended — it has no order to preserve.
    var position: Int?
    var done: Bool
    var doneAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    /// Where this sits in its meeting's list. Anything the live pass appended
    /// has no `position` of its own and falls to the end.
    var order: Int {
        position ?? .max
    }

    /// Still outstanding: a real task, not ticked off, not in the trash.
    ///
    /// `proposed` is excluded on purpose. The live pass is allowed to be wrong,
    /// and a bad minute of transcription must not inflate the commitments count
    /// on the Home screen — an item earns its place there once the recap
    /// corroborates it or the user acts on it.
    var isOpen: Bool {
        kind == .action && status == .confirmed && !done && deletedAt == nil
    }

    enum Kind: String, Codable, Equatable {
        case action
        case decision
        case question
        case risk
        case followUp = "follow_up"
    }

    enum Status: String, Codable, Equatable {
        /// The live pass found it; nothing has corroborated it yet.
        case proposed
        /// Real: the recap agreed, or the user acted on it.
        case confirmed
        /// A later moment in the meeting replaced it.
        case superseded
        /// The meeting decided against it. Not the same as the user deleting
        /// it — this is a thing the room said, and it belongs in the record.
        case dropped
    }

    enum Source: String, Codable, Equatable {
        case recap
        case live
        case user
    }

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case userID = "user_id"
        case text
        case deadline
        case kind
        case status
        case source
        case revisionOf = "revision_of"
        case evidenceIdx = "evidence_idx"
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
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(revisionOf, forKey: .revisionOf)
        try c.encodeIfPresent(evidenceIdx, forKey: .evidenceIdx)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
    }

    static func new(
        id: UUID = UUID(),
        meetingID: UUID,
        userID: UUID,
        text: String,
        deadline: String?,
        position: Int?,
        kind: Kind = .action,
        status: Status = .confirmed,
        source: Source = .recap,
        revisionOf: UUID? = nil,
        evidenceIdx: Int? = nil
    ) -> ActionItem {
        ActionItem(
            id: id,
            meetingID: meetingID,
            userID: userID,
            text: text,
            deadline: deadline,
            kind: kind,
            status: status,
            source: source,
            revisionOf: revisionOf,
            evidenceIdx: evidenceIdx,
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
        var copy = self
        copy.text = newText
        return copy
    }

    /// A copy with the done state flipped — used for the optimistic local
    /// update before `ActionItemStore.setDone` persists it.
    func marked(done: Bool, at date: Date?) -> ActionItem {
        var copy = self
        copy.done = done
        copy.doneAt = done ? date : nil
        return copy
    }

    /// A copy the recap has corroborated: a live guess that turned out to be
    /// right, taking its place in the recap's order.
    func confirmed(position: Int?) -> ActionItem {
        var copy = self
        copy.status = .confirmed
        copy.position = position
        return copy
    }
}
