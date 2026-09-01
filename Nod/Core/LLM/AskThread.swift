import Foundation

/// What the Ask box has already asked and already been told, this meeting.
///
/// The box answers one question at a time and shows one answer at a time, but
/// the person typing into it is having a conversation: "попереднє?" and "а в
/// якому каналі?" are whole questions to them and unanswerable strings to a
/// call that starts cold. Carrying the turns costs a few hundred tokens on the
/// prompts that already run; not carrying them makes every follow-up a
/// non-sequitur.
///
/// A value type the caller owns rather than state on the analyst, because the
/// thread belongs to the bar: it starts when a bar takes over and dies with it,
/// and both the recording analyst and the room listener answer into the same
/// one. Neither of them should have to agree with the other about whose turns
/// these are.
struct AskThread: Equatable {
    struct Turn: Equatable {
        let question: String
        let answer: String
    }

    private(set) var turns: [Turn] = []

    /// Enough for the follow-ups people actually type — a question, a
    /// clarification, a second clarification — without letting a long meeting's
    /// worth of Q&A crowd out the transcript in the same prompt.
    static let maxTurns = 6

    /// A summary answer runs to a paragraph, and a follow-up needs to know what
    /// was said, not to re-read all of it.
    private static let maxAnswerChars = 500

    mutating func append(question: String, answer: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answer.isEmpty else { return }
        turns.append(Turn(question: question, answer: answer))
        turns = Array(turns.suffix(Self.maxTurns))
    }

    /// The turns as a prompt block, oldest first, or empty when there are none.
    ///
    /// Trailing newline included when non-empty so a caller can interpolate it
    /// directly against the next block without composing around whether this
    /// one is there.
    var block: String {
        guard !turns.isEmpty else { return "" }
        let body = turns.map { turn in
            "Q: \(turn.question)\nA: \(turn.answer.prefix(Self.maxAnswerChars))"
        }.joined(separator: "\n")
        return "[EARLIER IN THIS ASK BOX]\n\(body)\n\n"
    }
}
