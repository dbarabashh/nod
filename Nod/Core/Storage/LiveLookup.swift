import Foundation

/// Something a connected tool holds right now, fetched because somebody in the
/// room asked for it out loud.
///
/// The third direction this surface can face, and its own type for that reason.
/// `LiveFinding` reports what was just said in this meeting; `LiveRecall` brings
/// back what an earlier meeting settled. Both are inward, and both are ours.
/// This one goes outward and comes back with something that is **live** — a
/// tracker's state, a channel's last hour — which is exactly why it must never
/// be folded into the other two: findings land in `action_items` at finalize,
/// and recall promises "what we knew". Neither claim is true of a number read
/// out of Linear thirty seconds ago, and one that was stored as if it were
/// would age into a lie nobody could date.
///
/// So nothing here is persisted. It exists for the length of the answer.
struct LiveLookup: Identifiable, Equatable {
    /// Where the lookup got to. Every terminal state is drawn, including the
    /// two that found nothing: the request was spoken aloud, in front of other
    /// people, and answering silence to a question the room heard is worse than
    /// answering "nothing".
    enum State: Equatable {
        case resolving
        case answered(Answer)
        /// The tool replied, and had nothing.
        case empty
        /// The tool could not be reached, or refused.
        case failed
        /// Not attempted, and why.
        case refused(Refusal)
    }

    enum Refusal: Equatable {
        /// Somebody on the invitation is not a colleague. Reading a tracker
        /// onto a shared screen in front of a customer is the case this whole
        /// gate exists for.
        case outsidersPresent
        /// Nothing connected can answer this. Not an error — an account with no
        /// integrations is the ordinary case.
        case noProvider

        var label: String {
            switch self {
            case .outsidersPresent: "Not everyone here is from your team"
            case .noProvider: "Nothing connected can answer that"
            }
        }
    }

    struct Answer: Equatable {
        /// One or two sentences, in the asker's own terms.
        let text: String
        /// Which product this came out of, or nil when it came out of the
        /// user's own earlier meetings.
        ///
        /// Present or absent, something always says where the claim is from —
        /// the same rule `LiveRecall` refuses to exist without. An answer read
        /// into a room is repeated by the people in it, and one they cannot
        /// place is one they cannot check.
        let provider: IntegrationProvider?
        /// What it was read from: an issue key, a channel name, or the session
        /// an earlier discussion happened in. Rendered beside the mark.
        let subject: String?
        /// When it was read. Shown because this is the one thing on the surface
        /// that can be stale by the time somebody finishes reading it.
        let readAt: Date
    }

    let id: UUID
    /// What was asked, with the address stripped, exactly as it was said.
    let request: String
    /// The provider the request was routed to, when one was chosen. Held even
    /// while resolving so the card can name what it is waiting on.
    let provider: IntegrationProvider?
    let askedAt: Date
    var state: State

    init(
        request: String,
        provider: IntegrationProvider?,
        state: State = .resolving,
        askedAt: Date = Date()
    ) {
        id = UUID()
        self.request = request
        self.provider = provider
        self.state = state
        self.askedAt = askedAt
    }

    /// Nothing more is coming. The card starts its expiry from here rather than
    /// from `askedAt`, so a slow tool does not eat the time somebody has to
    /// read the answer.
    var isSettled: Bool {
        state != .resolving
    }
}
