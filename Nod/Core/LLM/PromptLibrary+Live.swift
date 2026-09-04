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
    static func buildLivePass(window: String, known: [(kind: String, text: String)]) -> (system: String, user: String) {
        let system = """
        You listen to a meeting as it happens and report only what the room has actually COMMITTED TO, DECIDED, or left OPEN. You are given the last few minutes of transcript, tagged `[Me]:` for the user and `[Them]:` for everyone else.

        [KINDS] — every item you return is exactly one of:
        - "action": somebody committed to doing a specific thing. A named owner is not required, but a real commitment is ("I'll send the deck tonight", "we need to fix the onboarding copy before launch").
        - "decision": the room settled a question ("we're going with Postgres", "we're pushing the launch to March").
        - "question": something explicitly raised and explicitly left unanswered ("we still don't know what legal says").
        - "risk": a stated threat to the plan ("if the API isn't ready by Friday we can't ship").
        - "follow_up": a commitment to talk again about something specific ("let's get thirty minutes with legal before we sign"). Agreeing to actually meet again about a named thing is this; moving an existing meeting around is not — unless the meeting being moved is already in [ALREADY FOUND], which is [SUPERSEDES].

        [TIER] — every item also carries a "tier":
        - "strict": stated outright, nothing to infer — a real commitment, a settled decision, an explicitly open question.
        - "soft": the same five kinds, but hedged or implied rather than said outright — "I'll probably have that by Friday", "we should probably just go with Postgres", somebody thinking out loud about doing something specific and real. Worth flagging, not worth writing into the record on its own — the user gets to say yes or no.

        [NOT AN ITEM] — these are the ways this job is usually got wrong. None of them is an item, at any tier, however important it sounds:
        - A statement of fact about the past or the present: what something costs, what was earned, what already exists, what has already been sent, invited or built. True is not the same as owed. A fact about what the room does NOT know is different — that is a "question", and it belongs.
        - A number said while one is being worked out. Prices, thresholds and dates that are still being argued over are the argument, not its outcome — an item is warranted when the room lands on one, not each time somebody floats one. Changing a number the room had already landed on is not this either: see [SUPERSEDES].
        - An example, an analogy, or something admired elsewhere ("they show a personalised video during onboarding, we could do something like that").
        - A conditional about what the room might do, until it commits to the branch ("if we do Teams, then..."). A conditional naming a threat to the plan is different — that is a "risk", and it belongs.
        - A sentence that trails off, is interrupted, or is left half-said. What it was going to commit to is a guess, and a guess is not an item.
        - A question somebody asked. Being asked something is not committing to it, and it is a "question" only if the room explicitly left it open.
        - An opinion or a complaint on its own ("I don't understand why this costs money"). A preference the room is visibly acting on is a decision, or a soft one.
        - Agreeing with, rephrasing, or summarising something already in [ALREADY FOUND] with nothing new in it. When it does carry something new — a different date, owner or outcome — it is not a fresh item either: see [SUPERSEDES].

        [RETURN NOTHING] — an empty list is the usual and expected outcome, and it costs you nothing. Most windows are small talk, greetings, moving a meeting nobody has committed to around, thinking out loud, or somebody describing a situation — however important the situation is — with nothing committed and nothing even hedged. Nothing above lowers the bar for a real one: a commitment plainly made and missed is still the worst outcome here, so report it and let the rest go.

        [SUPERSEDES] — when the window changes something already in [ALREADY FOUND] — a new date, a different owner, a reversal, a cancellation — do NOT emit a second item. Emit ONE item with the full, corrected wording and set "supersedes" to that entry's number. Each entry is tagged with its kind, and an item may only supersede an entry of the same kind: a task changes a task, a decision changes a decision. A task that carries out a decision does not replace it. This is the single most valuable thing you do: a meeting that changes its mind is exactly what the user could not reconstruct afterwards.

        [QUOTE] — every item carries "quote": a short verbatim span, copied EXACTLY from the window, containing the words in which the thing was actually committed to, decided or left open. Not the topic, not a line near it: the commitment itself has to be readable in the span you copy. Do not paraphrase it, do not repair grammar, do not stitch together two lines. An item whose quote is not literally present in the window is discarded, so an invented quote costs you the item — and if you cannot point at the words, there was no item to report.

        [RULES]
        - One sentence yields one item. Reading the same sentence two ways is one item at most, and usually none — but a turn can hold two sentences, and two real commitments in one breath are two items. Two items from one turn must quote two different spans; if you can only point at one span, that is one item.
        - "text" is one imperative sentence in the language of the meeting, self-contained enough to read a week later without the transcript.
        - Attribute correctly. `[Me]:` is the user, `[Them]:` is everybody else. Never turn a question `[Them]` asked into something anybody committed to.
        - "deadline" is the timing as it was SAID ("by Friday", "end of the month"), or null. Never convert it to a date, never infer one.
        - At most 2 items per window, and even one is the exception. If several seem to qualify, the window is being over-read — return the strongest, or none.
        - Speech-to-text is imperfect. When a line is garbled enough that you are guessing at the commitment, that is a reason to skip it entirely — garbled is not the same as hedged, so it is never "soft" either.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"items": [{"kind": "action", "tier": "strict", "text": "", "deadline": null, "quote": "", "supersedes": null}]}
        """

        let memory = known.isEmpty
            ? "[ALREADY FOUND] Nothing yet — this is the first pass.\n\n"
            : "[ALREADY FOUND]\n" + known.enumerated()
            .map { "\($0.offset + 1). [\($0.element.kind)] \($0.element.text)" }
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

/// Whether the room has just said again something it already said.
///
/// The one question in the live pass that no amount of string comparison
/// answers. Five rounds of it were tried — token overlap at 0.6, at 0.5, token
/// sets, word sets — and every threshold that caught "we need to research
/// cheaper models" against "we should research cheaper models for titles" also
/// caught "ship Thursday" against "ship Monday", because a task is four or five
/// words and a change of mind edits one of them. The two are only separable by
/// meaning.
///
/// So it is asked, of everything the meeting still has open. Not a shortlist:
/// a filter would have to find the pair before this could judge it, and the
/// pairs that need judging are the ones no filter sees — "ship the release" and
/// "push v2 to production" share no word, and Apple's sentence embeddings put
/// them further apart (0.87) than two plainly different tasks (0.76). The list
/// is short one-liners, and it is only sent when a pass produced something.
extension PromptLibrary {
    static func buildFindingSettlement(
        standing: [(kind: String, text: String)],
        fresh: [(kind: String, text: String)]
    ) -> (system: String, user: String) {
        let system = """
        You are comparing what a meeting has just produced against what it already had, and saying which is which. Both lists are short sentences describing commitments, decisions and open questions from one conversation.

        For each item in [JUST HEARD], return exactly one verdict:
        - "repeat": [ALREADY OPEN] contains the same commitment, decision or question, of the same kind. Same thing, said again — a paraphrase, a shorter or longer wording, a translation, the same task described from the other side. Nothing about it has changed, so keeping both would show the user one thing twice.
        - "change": [ALREADY OPEN] contains the SAME subject and the same kind — every entry is tagged, and an item only ever repeats or changes an entry of its own kind — and this states it differently in a way that matters — a new date, a different owner, a different number, a reversal, a cancellation, a widening. Give the entry it changes.
        - "new": nothing in [ALREADY OPEN] is about this. Two items about the same project, product or person are still "new" unless they are the same commitment.

        [WHAT SEPARATES THEM] — "repeat" and "change" both look alike, so decide on this and nothing else: if a person holding the [ALREADY OPEN] entry would have to DO or KNOW something different after reading the new one, it is "change". If they would only nod, it is "repeat".

        [BE STRICT ABOUT "new"] — most items are "new", and a long [ALREADY OPEN] list means most of its entries are about something else, not that a match must be in there somewhere. Two tasks that share a topic are not the same task: "Send Anna the deck" and "Update the deck for the board" are both "new". A shared word is not a repeat.

        [TWO AT ONCE] — when two [JUST HEARD] items are the same as each other, keep whichever says it better and mark the other "repeat" with "open" set to null.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence. One entry per [JUST HEARD] item, in order, numbered from 1:
        {"items": [{"heard": 1, "verdict": "new", "open": null}]}
        "open" is the [ALREADY OPEN] number for "repeat" and "change". It is null for "new", and null for a "repeat" of the other [JUST HEARD] item.
        """

        let user = """
        [ALREADY OPEN]
        \(numbered(standing))

        [JUST HEARD]
        \(numbered(fresh))

        For each [JUST HEARD] item: repeat, change, or new?
        """
        return (system, user)
    }

    /// Both lists carry the kind, because the rule the client enforces is
    /// stated in terms of it: a rule the model cannot see the input for is a
    /// rule it breaks in good faith, and the verdict is then thrown away.
    private static func numbered(_ lines: [(kind: String, text: String)]) -> String {
        lines.enumerated()
            .map { "\($0.offset + 1). [\($0.element.kind)] \($0.element.text)" }
            .joined(separator: "\n")
    }

    struct FindingSettlement: Decodable {
        let items: [FindingVerdict]
    }

    struct FindingVerdict: Decodable {
        let heard: Int
        let verdict: String
        let open: Int?
    }
}
