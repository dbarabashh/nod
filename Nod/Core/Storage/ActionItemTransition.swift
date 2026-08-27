import Foundation

/// One move a loop made, and what moved it.
///
/// The row that makes a state arguable. "Probably done because NOD-85 went Done
/// in Linear" is a sentence somebody can disagree with; "done" is not, and a
/// state nobody can disagree with is one nobody can correct — which matters
/// because this will be wrong sometimes.
///
/// Append-only by construction: there is no update path and no delete. A wrong
/// transition is answered by a later one, the way `revision_of` answers a wrong
/// item, because losing the history is losing the thing worth having.
struct ActionItemTransition: Codable, Identifiable, Equatable {
    let id: UUID
    let actionItemID: UUID
    let userID: UUID
    let fromState: ActionItem.LoopState?
    let toState: ActionItem.LoopState
    let actor: Actor
    /// Shown, so it is written for a person: "NOD-85 is Done in Linear".
    let reason: String?
    /// What it was read from, named so the claim can be reopened rather than
    /// only displayed.
    let evidence: [Evidence]
    /// Absent when a person did it — their own act needs no probability.
    let confidence: Double?
    /// Which rule decided. A rule that turns out to close things wrongly has to
    /// be findable afterwards, and "the model did it" is not findable.
    let resolver: String?
    let at: Date?

    /// Who moved it. `system` is the only one that can be wrong in a way nobody
    /// chose, which is why it may never reach `confirmed` on its own.
    enum Actor: String, Codable, Equatable {
        case user
        case system
        case external
    }

    struct Evidence: Codable, Equatable {
        let provider: String?
        let key: String?
        let url: String?
        /// A transcript turn, when the evidence is something that was said.
        let meetingID: UUID?
        let idx: Int?
    }

    /// The caption, as a row shows it.
    ///
    /// The provider's or the meeting's own words where there are any, because a
    /// quote is checkable and a paraphrase is not. Falls back to naming what
    /// moved it, which is still more than the state alone says.
    var caption: String? {
        // Before anything else: what the person did to their own list is not a
        // finding, and a row narrating the reader's last click is noise.
        guard actor != .user else { return nil }
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return reason
        }
        return switch actor {
        case .external: evidence.first?.provider.map { "\($0) says so" }
        case .system: "worked out from a later meeting"
        case .user: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case actionItemID = "action_item_id"
        case userID = "user_id"
        case fromState = "from_state"
        case toState = "to_state"
        case actor
        case reason
        case evidence
        case confidence
        case resolver
        case at
    }

    init(
        id: UUID = UUID(),
        actionItemID: UUID,
        userID: UUID,
        fromState: ActionItem.LoopState?,
        toState: ActionItem.LoopState,
        actor: Actor,
        reason: String? = nil,
        evidence: [Evidence] = [],
        confidence: Double? = nil,
        resolver: String? = nil,
        at: Date? = nil
    ) {
        self.id = id
        self.actionItemID = actionItemID
        self.userID = userID
        self.fromState = fromState
        self.toState = toState
        self.actor = actor
        self.reason = reason
        self.evidence = evidence
        self.confidence = confidence
        self.resolver = resolver
        self.at = at
    }
}

/// What a tracker's state may do to a loop, and what it may not.
///
/// A merged pull request and a closed issue are good evidence and bad proof.
/// They say the work happened; they do not say the person who asked for it knows,
/// or that what was asked for is what was built. So an external system may carry
/// a loop as far as `probablyDone` and no further — closure stays with a person,
/// or with the person who was owed it.
///
/// The asymmetry is the point. Raising a loop wrongly costs a glance; closing one
/// wrongly loses the only record that it was ever owed.
enum LoopClosure {
    /// Never reached by inference, whatever a tracker says.
    static let requiresAPerson: Set<ActionItem.LoopState> = [.confirmed, .cancelled]

    static func mayInfer(_ state: ActionItem.LoopState) -> Bool {
        !requiresAPerson.contains(state)
    }

    /// Where a tracker's verdict lands.
    ///
    /// Reopening is symmetric and immediate: a tracker that says a thing is open
    /// again is answering the same question it answered before, and there is
    /// nothing to lose by believing it.
    static func state(forTrackerClosed closed: Bool) -> ActionItem.LoopState {
        closed ? .probablyDone : .open
    }
}
