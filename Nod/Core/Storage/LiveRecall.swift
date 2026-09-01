import Foundation

/// Something Nod already knew, raised because the room just made it relevant.
///
/// The opposite direction to `LiveFinding`: that one reports what was said in
/// *this* meeting, this one brings back what was said in an earlier one. It is
/// the whole claim of the product — that Nod remembers your work and returns it
/// at the moment it matters — and it is also the only thing the app says
/// unprompted while somebody is mid-sentence.
///
/// Which is why it always carries where it came from. A remembered fact with no
/// provenance is indistinguishable from a model making something up, and the
/// user has no way to check it without leaving the meeting.
struct LiveRecall: Identifiable, Equatable {
    /// Why this was worth interrupting for. Not decoration: the bar for each is
    /// different, and the prompt is told to classify before it is allowed to
    /// surface anything.
    enum Kind: String, Equatable {
        /// "You decided last week to keep pricing at $49."
        case decision
        /// A promise made earlier that this conversation is now touching.
        case commitment
        /// What is being said now goes against what was settled before. The
        /// highest-value case and the one worth the most interruption.
        case contradiction
        /// A number, price, limit or date stated before and needed now.
        case fact
        /// A question left open earlier that this moment could close.
        case unresolved

        var label: String {
            switch self {
            case .decision: "You decided this before"
            case .commitment: "You promised this"
            case .contradiction: "This contradicts what was decided"
            case .fact: "From your memory"
            case .unresolved: "This was left open"
            }
        }
    }

    /// Where the claim came from, because the two are believable in different
    /// ways and the card has to say which it is.
    ///
    /// A memory recall is a model's reading of an earlier session's summary: it
    /// can be a paraphrase, and it can be wrong about what the session meant. An
    /// open loop is a row that has been sitting in the user's own list since the
    /// day it was raised, and how long it has sat is the most interesting thing
    /// about it — "you promised this" and "you promised this seventeen days ago"
    /// are not the same sentence.
    enum Origin: Equatable {
        case memory
        case openLoop(days: Int)

        var isOpenLoop: Bool {
            self != .memory
        }
    }

    let id: UUID
    let kind: Kind
    /// One sentence, in the user's own terms — not a quote from the transcript
    /// and not a summary of the session.
    let text: String
    let sourceMeetingID: UUID
    /// "Product Sync · Aug 8" — rendered under the text so the claim is
    /// traceable without opening anything.
    let sourceLabel: String
    let origin: Origin
    let foundAt: Date
    /// Set when the recalled claim is a distilled concept rather than a raw
    /// passage. It is what makes the card correctable: a concept can be marked
    /// superseded in one tap, a paraphrased chunk cannot.
    let conceptID: UUID?
    /// Only for a contradiction over a concept: the sentence that becomes the
    /// claim's current version if the user confirms the room is right.
    let replacement: String?

    init(
        kind: Kind,
        text: String,
        sourceMeetingID: UUID,
        sourceLabel: String,
        origin: Origin = .memory,
        foundAt: Date = Date(),
        conceptID: UUID? = nil,
        replacement: String? = nil
    ) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.sourceMeetingID = sourceMeetingID
        self.sourceLabel = sourceLabel
        self.origin = origin
        self.foundAt = foundAt
        self.conceptID = conceptID
        self.replacement = replacement
    }

    /// Whether the card may offer "this replaces it": the room contradicted a
    /// concept, and the judge wrote down what the room said instead.
    var offersReplacement: Bool {
        kind == .contradiction && conceptID != nil
            && !(replacement ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How long it has been open, as the card says it. Nil for anything that is
    /// not a loop, and for a loop raised today: "0 days open" reads as a bug,
    /// and a promise made this morning is not yet a finding.
    var ageLabel: String? {
        guard case let .openLoop(days) = origin, days >= 1 else { return nil }
        return days == 1 ? "1 day open" : "\(days) days open"
    }
}
