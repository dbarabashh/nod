import Foundation

/// Something a connected tool holds right now, fetched because somebody asked
/// for it during a meeting.
///
/// Its own vocabulary rather than `LiveFinding`'s or `LiveRecall`'s.
/// `LiveFinding` reports what was just said in this meeting; `LiveRecall`
/// brings back what an earlier meeting settled. Both are inward, and both are
/// ours. This one goes outward and comes back with something that is **live** —
/// a tracker's state, a channel's last hour — which is exactly why it must
/// never be folded into the other two: findings land in `action_items` at
/// finalize, and recall promises "what we knew". Neither claim is true of a
/// number read out of Linear thirty seconds ago, and one that was stored as if
/// it were would age into a lie nobody could date.
///
/// So nothing here is persisted. It exists for the length of the answer.
enum LiveLookup {
    /// Where the lookup got to. Every terminal state has a caller that can say
    /// something about it: a question that was typed deserves an answer, and
    /// "found nothing" and "could not reach it" are different answers.
    enum State: Equatable {
        case answered(Answer)
        /// The tool replied, and had nothing.
        case empty
        /// Nothing came back, and whose fault that was.
        ///
        /// Distinct from `empty`, and the distinction is the whole point: a
        /// product that answered with nothing and one that never answered look
        /// identical from here, and reporting the second as the first tells
        /// somebody their Slack is quiet when really their Slack is unreachable.
        case failed(Failure)
        /// Not attempted, and why.
        case refused(Refusal)
    }

    enum Refusal: Equatable {
        /// Somebody on the invitation is not a colleague. Reading a tracker
        /// onto a shared screen in front of a customer is the case this whole
        /// gate exists for.
        case outsidersPresent
        /// The card was shown and the answer was no. Its own case rather than
        /// silence, because a request that was refused and one that was never
        /// understood look identical from an empty box.
        case declined

        var label: String {
            switch self {
            case .outsidersPresent: "Not everyone here is from your team"
            case .declined: "Not done — you didn't allow it"
            }
        }
    }

    /// Why nothing came back, said by whoever knows.
    ///
    /// Typed rather than a string, because the two read as opposite advice and
    /// the difference cannot be recovered from the words. A formatter reading
    /// English to guess got it wrong for the one message that mattered most: a
    /// Slack app missing a permission was announced as Slack being unreachable,
    /// which is what sends somebody to reconnect a healthy integration.
    enum Failure: Equatable {
        /// The product answered, and refused. Carried in its own words, because
        /// the adapter that raised it is the only thing that knows which
        /// failure it was, and "reconnect Slack in Settings" is something a
        /// person can act on where "Slack is unavailable" is not.
        case provider(IntegrationProvider, String?)
        /// The products answered and Nod could not turn it into a sentence.
        /// Naming a provider here would point at an integration that works.
        case nod(String)

        var label: String {
            switch self {
            case let .nod(said):
                said
            case let .provider(provider, said):
                if let said, !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    "\(provider.displayName): \(said)"
                } else {
                    "Couldn't reach \(provider.displayName)"
                }
            }
        }
    }

    /// A tool was reached and had nothing to say about the question.
    ///
    /// Its own sentence because "nothing in Slack" and "no access to Slack" are
    /// different facts, and only the first one is ever true here — by the time
    /// this is reachable the tool has already answered. The second is what the
    /// box said instead when this case had no words of its own, and a claim
    /// about what the user has connected is not one this surface can make.
    static func nothingFound(in provider: IntegrationProvider) -> String {
        "Checked \(provider.displayName), nothing there answers that"
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
        /// an earlier discussion happened in. Shown beside the product.
        let subject: String?
    }
}
