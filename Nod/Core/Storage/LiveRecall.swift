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

    let id: UUID
    let kind: Kind
    /// One sentence, in the user's own terms — not a quote from the transcript
    /// and not a summary of the session.
    let text: String
    let sourceMeetingID: UUID
    /// "Product Sync · Aug 8" — rendered under the text so the claim is
    /// traceable without opening anything.
    let sourceLabel: String
    let foundAt: Date

    init(
        kind: Kind,
        text: String,
        sourceMeetingID: UUID,
        sourceLabel: String,
        foundAt: Date = Date()
    ) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.sourceMeetingID = sourceMeetingID
        self.sourceLabel = sourceLabel
        self.foundAt = foundAt
    }
}
