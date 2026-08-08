import Foundation

/// Something the live pass heard while the meeting was still running, before
/// there is anywhere to put it.
///
/// It is not an `ActionItem` yet, and deliberately so: `action_items.meeting_id`
/// is a foreign key, and the meeting's own row does not reach the server until
/// the recording ends. Writing during the call would mean inserting a meeting
/// row at the first word — one that may never be finalized, may be started
/// offline, and would have to be reconciled by the outbox. The findings cost
/// nothing to hold, and the only thing lost by holding them is a crash
/// mid-meeting, which loses the meeting anyway.
///
/// So the whole lifecycle happens here in memory, and lands as rows once, at
/// finalize, with its history intact — which is what `revision_of`, `source` and
/// `evidence_idx` on the table are for.
struct LiveFinding: Identifiable, Equatable {
    /// How sure the live pass was. A "strict" finding was stated outright and is
    /// written to the record on its own; a "soft" one was hedged or implied —
    /// real enough to flag mid-meeting, not confident enough to survive without
    /// the user's own say-so, so dismissing one actually drops it. See
    /// `LiveMeetingAnalyst.rejectNotice`.
    enum Tier: String, Equatable {
        case strict
        case soft
    }

    /// Whether this is still what the live pass would tell you right now.
    /// A single property rather than two independent flags, because the two
    /// ways of falling out of standing — the room moving on, the user vetoing
    /// it — are mutually exclusive by nature, not by accident of call order.
    enum State: Equatable {
        /// Still standing: current, live, open to being read as memory.
        case standing
        /// Replaced by something said later — see `revisionOf` on the
        /// replacement. Kept rather than removed: the two halves of a change
        /// of mind are the interesting part.
        case superseded
        /// The user's own tap on a soft suggestion's dismiss glyph — see
        /// `Tier` and `LiveMeetingAnalyst.dismissNotice(userRejected:)`.
        case dismissed
    }

    let id: UUID
    let kind: ActionItem.Kind
    let text: String
    let tier: Tier
    /// A deadline as it was said out loud ("by Friday"), when one was.
    let deadline: String?
    /// The transcript line this came from, as a best-effort anchor for "why
    /// does this exist, who said it". Best-effort because a late chunk can still
    /// insert itself earlier within the reorder horizon and shift what follows
    /// by a line — which is a wrong neighbour, not a dangling pointer, and is
    /// why this is the index and not the entry's id (a dedup swap reissues ids).
    let evidenceIdx: Int?
    /// The earlier finding this replaces — "we said Thursday, now it's Monday".
    let revisionOf: UUID?
    let foundAt: Date

    var state: State = .standing

    /// The row this becomes at finalize. Superseded and dismissed both retire
    /// the row, but into the same `dropped` column value — `action_items.status`
    /// has no room today to tell "the room moved on" from "the user said no",
    /// and adding that distinction is a schema change, not a live-pass one.
    var resolvedStatus: ActionItem.Status {
        switch state {
        case .superseded: .superseded
        case .dismissed: .dropped
        case .standing: kind == .action ? .proposed : .confirmed
        }
    }

    /// What the live pass heard, as lines for the recap prompt.
    ///
    /// The recap reads the whole transcript in one go and is the authority; this
    /// is a hint, in the same spirit as the participant list. It earns its place
    /// in the prompt on one case above all: a meeting that changed its mind.
    /// Read cold, "let's ship Thursday" and "make it Monday" are two sentences
    /// twenty minutes apart with nothing tying them together, and a summary that
    /// reports both — or picks the first — is the failure the user notices.
    /// Here the pair is already known, so it can be stated as one line.
    static func notes(from findings: [LiveFinding]) -> [String] {
        let byID = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return findings.compactMap { finding -> String? in
            guard finding.state != .dismissed else { return nil }
            if let earlierID = finding.revisionOf, let earlier = byID[earlierID] {
                return "changed: \"\(earlier.text)\" became \"\(finding.text)\""
            }
            guard finding.state != .superseded else { return nil }
            let deadline = finding.deadline.map { " (\($0))" } ?? ""
            return "\(finding.kind.rawValue): \(finding.text)\(deadline)"
        }
    }

    init(
        kind: ActionItem.Kind,
        text: String,
        tier: Tier = .strict,
        deadline: String? = nil,
        evidenceIdx: Int? = nil,
        revisionOf: UUID? = nil,
        foundAt: Date = Date()
    ) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.tier = tier
        self.deadline = deadline
        self.evidenceIdx = evidenceIdx
        self.revisionOf = revisionOf
        self.foundAt = foundAt
    }
}
