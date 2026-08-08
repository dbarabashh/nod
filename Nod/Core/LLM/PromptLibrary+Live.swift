import Foundation

/// What a meeting is deciding, while it is still deciding it.
///
/// Every other prompt in this library reads a finished recording. This one runs
/// perhaps thirty times during a call, on a window of the last few minutes, and
/// its output is the only thing Nod can say before the meeting is over. The
/// prompt is therefore written around one instruction that the others do not
/// need: **most windows contain nothing, and returning nothing is the correct
/// answer.** A model that finds something in every window turns the notch into a
/// ticker, and a ticker is ignored within a day.
extension PromptLibrary {
    /// One pass over the recent transcript, given what has already been found.
    ///
    /// `known` is the memory: the findings still standing, numbered, so the model
    /// can point at one with `supersedes` instead of emitting a near-duplicate.
    /// It is what keeps a task discussed for ten minutes from becoming ten
    /// separate tasks — and it is why this call is worth its own memory at all
    /// rather than being a stateless extraction repeated on a sliding window.
    static func buildLivePass(window: String, known: [String]) -> (system: String, user: String) {
        let system = """
        You listen to a meeting as it happens and report only what the room has actually COMMITTED TO, DECIDED, or left OPEN. You are given the last few minutes of transcript, tagged `[Me]:` for the user and `[Them]:` for everyone else.

        [KINDS] — every item you return is exactly one of:
        - "action": somebody committed to doing a specific thing. A named owner is not required, but a real commitment is ("I'll send the deck tonight", "we need to fix the onboarding copy before launch").
        - "decision": the room settled a question ("we're going with Postgres", "we're pushing the launch to March").
        - "question": something explicitly raised and explicitly left unanswered ("we still don't know what legal says").
        - "risk": a stated threat to the plan ("if the API isn't ready by Friday we can't ship").
        - "follow_up": a commitment to talk again about something specific.

        [TIER] — every item also carries a "tier":
        - "strict": stated outright, nothing to infer — a real commitment, a settled decision, an explicitly open question.
        - "soft": the same five kinds, but hedged or implied rather than said outright — "I'll probably have that by Friday", "we should probably just go with Postgres", somebody thinking out loud about doing something specific and real. Worth flagging, not worth writing into the record on its own — the user gets to say yes or no.

        [RETURN NOTHING] — return an empty list, which is still the usual and expected outcome, when the window is:
        - small talk, greetings, scheduling, or thinking out loud with nothing specific attached,
        - somebody describing a situation, however important, with nothing committed and nothing even hedged,
        - a restatement of something already in [ALREADY FOUND] with no new information.

        [SUPERSEDES] — when the window changes something already in [ALREADY FOUND] — a new date, a different owner, a reversal, a cancellation — do NOT emit a second item. Emit ONE item with the full, corrected wording and set "supersedes" to that entry's number. This is the single most valuable thing you do: a meeting that changes its mind is exactly what the user could not reconstruct afterwards.

        [QUOTE] — every item carries "quote": a short verbatim span, copied EXACTLY from the window, that a person could read and agree the item follows from. Do not paraphrase it, do not repair grammar, do not stitch together two lines. An item whose quote is not literally present in the window is discarded, so an invented quote costs you the item.

        [RULES]
        - "text" is one imperative sentence in the language of the meeting, self-contained enough to read a week later without the transcript.
        - "deadline" is the timing as it was SAID ("by Friday", "end of the month"), or null. Never convert it to a date, never infer one.
        - At most 2 items per window. If more seem to qualify, the window is being over-read — return the strongest.
        - Speech-to-text is imperfect. When a line is garbled enough that you are guessing at the commitment, that is a reason to skip it entirely — garbled is not the same as hedged, so it is never "soft" either.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"items": [{"kind": "action", "tier": "strict", "text": "", "deadline": null, "quote": "", "supersedes": null}]}
        """

        let memory = known.isEmpty
            ? "[ALREADY FOUND] Nothing yet — this is the first pass.\n\n"
            : "[ALREADY FOUND]\n" + known.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n") + "\n\n"

        let user = """
        \(memory)[WINDOW — the last few minutes]

        \(window)

        Report what this window commits to, decides, or leaves open. Empty is a correct answer.
        """
        return (system, user)
    }

    /// The live pass's reply. `supersedes` is 1-based into the `known` list the
    /// prompt numbered; anything out of range is treated as absent, since a
    /// model pointing at a nonexistent entry has told us nothing.
    struct LivePassResult: Decodable {
        let items: [LivePassItem]
    }

    struct LivePassItem: Decodable {
        let kind: String
        /// Nullable because the model is free-text underneath the schema, and a
        /// missing or malformed value is treated as "strict" by the caller — the
        /// bar the whole feature ran on before tiering existed.
        let tier: String?
        let text: String
        let deadline: String?
        let quote: String
        let supersedes: Int?
    }
}
