import Foundation

/// The gate on the one thing Nod says without being asked.
///
/// Semantic similarity is what *found* the candidates; it is not a reason to
/// interrupt. Retrieval will always return the closest thing it has, and the
/// closest thing to a conversation about pricing is every previous conversation
/// about pricing — nearly all of which the user remembers perfectly well.
///
/// So the model is asked to reject by default, and the prompt spends its length
/// on what does *not* qualify. One useful interruption per meeting beats five
/// accurate-but-obvious ones: the cost of a weak note is not the note, it is
/// that the next one gets ignored too.
extension PromptLibrary {
    static func buildMemoryRecall(
        window: String,
        candidates: [String],
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You decide whether to interrupt someone who is in a meeting right now.

        You are given what is being said at this moment, and excerpts from the user's own earlier sessions that a search brought back. Almost always the correct answer is to say nothing.

        SURFACE only when the excerpt is ALL of:
        - specific — an explicit decision, a promise, a number, a date, a limit, or a question left open. Not a topic, not a discussion, not a general note.
        - relevant to THIS moment — it bears on the sentence being said now, not on the meeting's general subject.
        - useful NOW — knowing it changes what the user says next. If they would only nod, it is not useful.
        - probably not already in their head — something from weeks ago, a precise figure, or a commitment they made in passing. What was said an hour ago is not a recall.

        The strongest case, and the one to look hardest for: what is being said now CONTRADICTS what was settled earlier.

        DO NOT SURFACE:
        - a related note, or a previous meeting on the same topic
        - a summary of an earlier session
        - a weak or merely semantic match
        - anything obvious, or that the user has clearly just said themselves
        - true and relevant context that changes nothing right now

        If two excerpts qualify, return the one that would change the conversation most. Never return more than one.

        CLASSIFY what you return:
        - "contradiction" — now goes against what was decided before
        - "decision" — an explicit earlier decision
        - "commitment" — an earlier promise
        - "fact" — a number, price, limit, date stated before
        - "unresolved" — a question left open that this moment could close

        WRITE the text as one sentence, in \(lang), in the user's own terms — what they decided or promised or said, not "the transcript mentions". No preamble, no hedging, no quotes around it.

        For "contradiction" ONLY, also WRITE `replacement`: one sentence, in \(lang), stating what is being said NOW \
        — the new position that contradicts the old one, as a standalone fact. Empty for every other kind.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"surface": false, "source": 0, "kind": "", "text": "", "replacement": ""}
        `surface` is false unless every bar above is cleared. When true, `source` is the number of the excerpt you used.
        """

        let numbered = candidates.enumerated()
            .map { "[\($0.offset + 1)]\n\($0.element)" }
            .joined(separator: "\n\n")

        let user = """
        [BEING SAID NOW]
        \(window)

        [FROM EARLIER SESSIONS]
        \(numbered)

        Should anything be surfaced?
        """
        return (system, user)
    }

    struct MemoryRecallResult: Decodable {
        let surface: Bool
        let source: Int?
        let kind: String?
        let text: String?
        /// Only for a contradiction: what the room is saying now, as the
        /// sentence that would replace the recalled fact if the user agrees.
        let replacement: String?
    }
}
