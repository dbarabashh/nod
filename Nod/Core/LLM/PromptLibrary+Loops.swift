import Foundation

/// Reading a finished meeting against what was already open.
///
/// The model is never asked for a state. It is given a numbered list and asked
/// which numbers the conversation moved, and what was said that moved them —
/// then deterministic code checks every number is in range, maps the verb onto
/// a state, and refuses any move that would close a loop. A model that returns
/// nonsense returns nonsense indices, and nonsense indices are dropped.
///
/// One call for the whole meeting, not one per loop. Thirty candidates and a
/// transcript is a page; four hundred calls is a bill.
extension PromptLibrary {
    struct LoopMoves: Decodable {
        let moved: [LoopMove]
    }

    struct LoopMove: Decodable {
        /// An index into the numbered list the prompt showed. Checked against
        /// that list before anything is written.
        let loop: Int
        /// What the conversation did to it, in the three words the prompt
        /// allows. Anything else is dropped.
        let to: String
        /// The sentence that says so, copied. Shown to the person as the
        /// reason, so a move they disagree with is one they can see the basis
        /// for and undo.
        let said: String?
    }

    static func buildLoopResolution(
        loops: [ActionItem],
        transcript: String,
        meetingTitle: String,
        now: Date = Date()
    ) -> (system: String, user: String) {
        let numbered = loops.enumerated()
            .map { index, loop in "\(index). \(loop.text)" }
            .joined(separator: "\n")

        let system = """
        A meeting just finished. Below it is a numbered list of things that were left unresolved in
        *earlier* meetings. Say which of them this conversation moved, and quote the words that moved it.

        \(nowBlock(now))

        - Only report a number when the conversation genuinely bears on it.
        - Silence is the ordinary answer. Most conversations move nothing, and a list that moves something every time is one nobody trusts twice.
        - `done` means somebody said the thing happened — "I sent it", "that's merged", "we shipped it".
        - `progressed` means it is under way and not finished — "I started on it", "half of it is up".
        - `blocked` means it is waiting on something named.
        - Never report a number for something merely *mentioned*. Talking about a promise is not keeping it.
        - `said` is copied from the transcript, not written by you. It is shown to the person as the reason.
        - A reason they cannot find in the conversation is worse than no reason at all.
        - A thing this meeting decided to do for the first time is not on the list and is not your concern here.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"moved": [{"loop": 0, "to": "done", "said": "…"}]}
        Use {"moved": []} when the conversation moved nothing, which is the common case.
        """

        let user = """
        [MEETING] \(meetingTitle)

        [STILL OPEN FROM EARLIER]
        \(numbered)

        [WHAT WAS SAID]
        \(transcript)

        Which numbers did this move?
        """

        return (system, user)
    }

    /// A meeting's worth of talk, capped. The end rather than the start: what a
    /// conversation resolved is said as it winds up, and the opening is
    /// pleasantries.
    ///
    /// Exposed so the caller picks its candidates from the same words the model
    /// is shown, rather than from a transcript this then truncates behind it.
    static func loopTranscript(_ transcript: String) -> String {
        String(transcript.suffix(loopTranscriptBudget))
    }

    private static let loopTranscriptBudget = 12_000

    struct OpenLoopRecall: Decodable {
        /// An index into the numbered list, or nil for the ordinary answer.
        let loop: Int?
        /// One sentence, shown on the card. Nil is treated as no answer.
        let say: String?
    }

    /// Whether the room, right now, is standing on something the user already
    /// owes — and what to say about it.
    ///
    /// A different question from `buildLoopResolution`, which reads a finished
    /// meeting and asks what moved. This one runs mid-sentence, and the cost of
    /// being wrong is not a bad row in a list: it is interrupting a person who
    /// is talking. So the bar is higher, only one answer is allowed, and the
    /// prompt says outright that silence is the expected outcome.
    static func buildOpenLoopRecall(
        loops: [ActionItem],
        window: String,
        language: AppLanguage = .english,
        now: Date = Date()
    ) -> (system: String, user: String) {
        let numbered = loops.enumerated()
            .map { index, loop in "\(index). \(loop.text)" }
            .joined(separator: "\n")

        let system = """
        You decide whether to interrupt someone who is talking right now.

        You are given what is being said at this moment, and a numbered list of things the user still owes or is still owed, from *earlier* meetings. Almost always, say nothing.

        \(nowBlock(now))

        SURFACE one only when ALL of these hold:
        - The conversation is genuinely standing on that loop — the thing itself is being discussed, decided, or asked about right now.
        - Knowing it changes what the user says in the next minute. If they would only nod, stay silent.
        - The room has not already covered it. Somebody who just said "I still owe you the deck" does not need to be told.

        DO NOT SURFACE:
        - a loop that merely shares a word or a topic with what is being said
        - a loop somebody in the room has already brought up
        - anything the user has obviously kept in mind
        - more than one loop, ever

        If two qualify, take the one that has been open longest — the recent one is still in their head and the old one is why this exists.

        WRITE `say` as one sentence, in \(language.promptName), in the user's own terms: what is outstanding, not an instruction to do it. No preamble, no hedging, no quotes around it.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"loop": null, "say": null}
        Use a number only when every bar above is cleared.
        """

        let user = """
        [BEING SAID NOW]
        \(window)

        [STILL OPEN FROM EARLIER]
        \(numbered)

        Should any of these be surfaced right now?
        """

        return (system, user)
    }
}
