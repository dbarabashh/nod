import Foundation

/// Something Nod is offering to do in a connected product, before it does it.
///
/// Wire compatible with `action_proposals` (`20260816220000_action_proposals.sql`).
///
/// Distinct from `ActionItem`, which is the user's own checklist and carries no
/// owner on purpose. This is where a claim about somebody else lives, and the
/// whole reason it is a separate object is that such a claim has to be confirmed
/// by a person before it becomes true anywhere.
struct ActionProposal: Codable, Identifiable, Equatable {
    let id: UUID
    let userID: UUID
    let meetingID: UUID?
    let actionItemID: UUID?
    let type: String
    var status: Status
    var parameters: [String: String]
    var confidence: Double?
    /// The measurements behind `confidence`, kept so re-measuring one claim
    /// does not throw away the others — and so a proposal can answer why it
    /// scored what it scored.
    var confidenceParts: [String: Double]?
    var evidenceIdx: Int?
    let createdAt: Date?
    var externalProvider: String?
    var externalKey: String?
    var externalURL: String?
    var failureMessage: String?
    /// The agent that prepared it, when one did. Authorship, not authority:
    /// an agent's draft takes exactly the approve path a pipeline draft takes.
    var raisedByAgent: UUID?
    /// True when a standing grant approved it with nobody watching — the card
    /// has to say so, because "filed" and "filed by itself" are different
    /// promises kept.
    var autoApproved: Bool?

    /// `provider.action` — the same split `registry.ts` dispatches on, so
    /// nothing between here and the adapter has to learn a provider's name.
    var provider: IntegrationProvider? {
        type.firstIndex(of: ".").flatMap { IntegrationProvider(rawValue: String(type[type.startIndex ..< $0])) }
    }

    var action: String {
        type.firstIndex(of: ".").map { String(type[type.index(after: $0)...]) } ?? type
    }

    /// What the user reads on the review card. The title is what a tracker will
    /// show, so it is the honest summary of what is about to happen.
    var headline: String {
        parameters["title"] ?? parameters["channel_name"] ?? action
    }

    enum Status: String, Codable, Equatable {
        /// Found, and nobody has looked at it.
        case proposed
        /// Missing something only a person can supply — an owner who did not
        /// resolve, a target that could be one of several.
        case needsReview = "needs_review"
        /// Could be approved exactly as it stands.
        case ready
        case approved
        case executing
        case completed
        case failed
        case rejected
        /// Re-raised under another verb; neither a yes nor a no.
        case withdrawn
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case meetingID = "meeting_id"
        case actionItemID = "action_item_id"
        case type
        case status
        case parameters
        case confidence
        case confidenceParts = "confidence_parts"
        case evidenceIdx = "evidence_idx"
        case createdAt = "created_at"
        case externalProvider = "external_provider"
        case externalKey = "external_key"
        case externalURL = "external_url"
        case failureMessage = "failure_message"
        case raisedByAgent = "raised_by_agent"
        case autoApproved = "auto_approved"
    }
}

/// How far a proposal may be trusted, taken apart into the claims it makes.
///
/// A single number from the model would make the thresholds decorative — a
/// language model asked how sure it is answers with a mood. `owner` is measured
/// by code that can be wrong in a way a test can catch: whether the person named
/// in the conversation resolved to exactly one colleague, or to none, or to
/// three.
///
/// Only the claims actually being made are scored. A task with no assignee makes
/// no claim about an owner, and scoring it as an unresolved one would punish the
/// proposal for being honest about what it does not know. Further parts — which
/// tracker team, whether a stated deadline became a real date — arrive with the
/// proposals that make those claims; today none does, and a part nothing writes
/// would be a threshold that never fires.
struct ProposalConfidence: Equatable {
    enum Part: String, Equatable, CaseIterable {
        /// The pass that produced it. A self-assessment of a kind, and never
        /// sufficient alone — it is a ceiling the measured parts pull down.
        case semantic
        /// Whether the person named resolved to exactly one colleague.
        case owner
    }

    private(set) var parts: [Part: Double]

    init(semantic: Double) {
        parts = [.semantic: max(0, min(1, semantic))]
    }

    /// Rebuilt from what was stored, so re-measuring one part does not silently
    /// re-measure the rest. Reconstructing from `overall` alone would take the
    /// weakest part as the reading of every part — an owner named after the fact
    /// would then be held down by the score its own absence had caused.
    init(stored: [String: Double]) {
        parts = stored.reduce(into: [Part: Double]()) { table, pair in
            guard let part = Part(rawValue: pair.key) else { return }
            table[part] = max(0, min(1, pair.value))
        }
        if parts[.semantic] == nil { parts[.semantic] = 0 }
    }

    mutating func record(_ part: Part, _ value: Double) {
        parts[part] = max(0, min(1, value))
    }

    var stored: [String: Double] {
        parts.reduce(into: [String: Double]()) { table, pair in
            table[pair.key.rawValue] = pair.value
        }
    }

    /// The weakest claim, not the average.
    ///
    /// An average lets a well-written title compensate for not knowing who is on
    /// the hook, which is precisely the trade this product must not make.
    var overall: Double {
        parts.values.min() ?? 0
    }

    /// Below this, a claim is not something to hand to a person as ready.
    static let readyThreshold = 0.9
    /// Below this, a claim is missing rather than weak, and needs an answer
    /// before the proposal means anything.
    static let unusableThreshold = 0.5

    var status: ActionProposal.Status {
        if parts.values.contains(where: { $0 < Self.unusableThreshold }) {
            .needsReview
        } else if overall >= Self.readyThreshold {
            .ready
        } else {
            .proposed
        }
    }
}

/// Turning a name heard in a meeting into somebody Nod can address.
///
/// Never guesses. `18.1 Conservative execution` is the rule it exists to keep:
/// "someone should investigate OAuth" produces a proposal with no owner, not a
/// proposal assigned to whoever usually does that work.
enum PersonResolver {
    enum Outcome: Equatable {
        /// Exactly one colleague, with how far that match may be trusted.
        case resolved(personID: UUID, name: String, confidence: Double)
        /// The name fits more than one person. A question for the user, never a
        /// coin toss.
        case ambiguous(names: [String])
        case unknown
    }

    /// A speaker the user themselves identified outranks any name match — they
    /// were in the room, and the match is a string comparison.
    static let confirmedConfidence = 1.0
    static let nameMatchConfidence = 0.9
    static let ambiguousConfidence = 0.3

    static func resolve(
        _ name: String?,
        in directory: [Person],
        confirmedSpeakers: [MeetingSpeaker] = []
    ) -> Outcome {
        let wanted = normalized(name ?? "")
        guard !wanted.isEmpty else { return .unknown }

        // Somebody the user pointed at during this very meeting, by the name the
        // recap used for them.
        if let speaker = confirmedSpeakers.first(where: {
            $0.isActionable && normalized($0.displayName ?? "") == wanted
        }), let personID = speaker.personID {
            return .resolved(
                personID: personID,
                name: speaker.displayName ?? wanted,
                confidence: confirmedConfidence
            )
        }

        let candidates = directory.filter { isMatch(wanted, $0) }
        guard let only = candidates.first else { return .unknown }
        guard candidates.count == 1 else {
            return .ambiguous(names: candidates.map(\.name).sorted())
        }
        return .resolved(personID: only.personID, name: only.name, confidence: nameMatchConfidence)
    }

    /// Whole tokens only. A prefix match turns "Al" into Alex and "Sam" into
    /// Samantha, and an assignment made on a prefix is a ticket in the wrong
    /// person's queue.
    private static func isMatch(_ wanted: String, _ person: Person) -> Bool {
        let candidates = [
            normalized(person.displayName ?? ""),
            normalized(person.name),
            normalized(person.email.map { String($0.prefix(while: { $0 != "@" })) } ?? "")
        ]
        if candidates.contains(wanted) { return true }
        // "Alex" against "Alex Smith": a given name is how people are referred
        // to out loud, and it is still a whole token.
        return candidates.contains { $0.split(separator: " ").first.map(String.init) == wanted }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }
}
