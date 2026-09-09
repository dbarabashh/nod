import Foundation

/// Answering a question asked during a meeting out of a connected tool.
///
/// Bounded rather than an open tool loop. The chat can take as many rounds as
/// an answer needs; this cannot, because it runs while a conversation is going
/// on and an answer that arrives after the room moved on is worse than none.
///
/// So: route once, read once, and at most one further read — offered only
/// because the catalogues themselves are two-step. "Which channel did we
/// discuss that in" cannot be answered without listing the channels first, and
/// a single hop turned that question into a list of channel names, which is
/// not an answer to anything anybody asks.
private enum LookupChoiceKey: String, CodingKey {
    case tool
    case arguments
}

extension PromptLibrary {
    struct LookupChoice: Decodable {
        /// The tool to run, or nil when none of them answers this.
        let tool: String?
        /// Arguments for it, as the schema describes them.
        ///
        /// Flattened to strings because that is what a tool call carries, but
        /// decoded from whatever JSON scalar arrived. A schema that says
        /// "1-200" gets `"limit": 50`, and a model is right to send a number
        /// there — rejecting it threw away a correct call and reported it as
        /// the provider being unreachable.
        let arguments: [String: String]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: LookupChoiceKey.self)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            arguments = try container.decodeIfPresent([String: JSONScalar].self, forKey: .arguments)?
                .compactMapValues(\.stringValue)
        }
    }

    /// One JSON value as a tool argument can carry it.
    ///
    /// Null decodes to nothing rather than "null": an argument the model chose
    /// to leave out must not reach a provider as the four-letter string.
    ///
    /// A list is joined by `ToolArguments.joined`, which owns that rule for
    /// both decoders. This routing call is free-form JSON with nothing
    /// enforcing the schema, so `attendees` arrives as an array routinely.
    fileprivate struct JSONScalar: Decodable {
        let stringValue: String?

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                stringValue = nil
            } else if let text = try? value.decode(String.self) {
                stringValue = text
            } else if let number = try? value.decode(Int.self) {
                stringValue = String(number)
            } else if let flag = try? value.decode(Bool.self) {
                stringValue = String(flag)
            } else if let number = try? value.decode(Double.self) {
                stringValue = String(number)
            } else if let list = try? value.decode([JSONScalar].self) {
                stringValue = ToolArguments.joined(list.map(\.stringValue))
            } else {
                // An object. Nothing a tool argument takes, and passing its
                // description on would be worse than omitting it.
                stringValue = nil
            }
        }
    }

    struct LookupAnswer: Decodable {
        /// One more read, when what came back names the thing to read but does
        /// not contain it. Nil whenever the answer is already possible, which
        /// is the ordinary case — most questions are one read deep.
        let next: LookupChoice?
        /// One or two sentences, or empty when nothing gathered answers it.
        let text: String
        /// What it was read from — an issue key, a channel name, a session —
        /// or empty.
        let subject: String?
        /// Whether the tool's result is actually part of the answer. Decides
        /// which mark the card shows, so it is asked for rather than inferred
        /// from a tool merely having been run.
        let usedTool: Bool?
    }

    /// The tools as the model reads them. Shared by the routing call and the
    /// follow-up read, so a tool cannot be described one way when it is chosen
    /// and another way when it is chosen again.
    private static func catalogue(_ tools: [ChatTool]) -> String {
        let body = tools.map { tool in
            let args = tool.parameters.properties
                .map { "\($0.key): \($0.value.description)" }
                .sorted()
                .joined(separator: "; ")
            let required = tool.parameters.required.joined(separator: ", ")
            return "- \(tool.name): \(tool.description)\n  arguments — \(args)\n  required — \(required.isEmpty ? "none" : required)"
        }.joined(separator: "\n")
        return "[TOOLS]\n\(body.isEmpty ? "None." : body)"
    }

    static func buildLookupRouting(
        request: String,
        tools: [ChatTool],
        thread: AskThread = AskThread(),
        transcript: String = "",
        now: Date = Date()
    ) -> (system: String, user: String) {
        let system = """
        Somebody in a meeting typed a request to Nod. It is either a question about what a connected product
        holds, or an instruction to do something in one. Choose the one tool that serves it, and its arguments.

        \(nowBlock(now))

        - Choose nothing rather than something close. A wrong call wastes the moment it was asked in, and the person will simply ask again.
        - A request about the conversation rather than about a product is not a tool call. Choose nothing.
        - "And the previous one?", "say that again", "what did you just tell me" are answered from [EARLIER IN THIS ASK BOX].
        - [IN THE ROOM] is what is being said right now. It is what resolves a request that leaves its subject
        out — "that ticket", "the channel we just mentioned", "her" — and it is where an id, a name or a date
        said out loud but not typed comes from.
        - It does not turn a request about the conversation into a tool call. Still choose nothing for those.
        - Never carry the room's words into an argument beyond what is being looked for. A search takes the
        thing, not the sentence it was said in.
        - Fill every required argument or choose nothing. A call missing one is not made, and the turn is spent.
        - A tool that changes something is chosen only when the request asks for it: "file that", "open a channel for it", "put it on the calendar".
        - A question about what exists is never served by a tool that creates something.
        - When it does ask for it, choose the tool that does it. The person is shown exactly what it would do
        and has to allow it, so the choice here is not the decision; leaving them nothing to allow is.
        - Only fill an argument the request actually supports. Never invent an id, a channel or a name that was not said. Dates are the exception and come from [NOW], never from memory.
        - If a tool needs an id the request does not give, choose the tool that finds it by name instead. If there is none, choose nothing.
        - The request was spoken, so it arrives punctuated by a transcriber and may be clipped. Read it for intent, not for grammar.
        - [EARLIER IN THIS ASK BOX] is the conversation this request continues. Resolve the request against those turns before deciding.
        - "And the other channel?" is a lookup; which lookup it is was settled two turns ago.
        - A tool that only lists or searches is a legitimate choice when the request names a thing by name rather than by id. What it finds can be read in a second step.

        \(catalogue(tools))

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"tool": "", "arguments": {}}
        Use {"tool": null, "arguments": null} when nothing here answers the request.
        """

        return (system, "\(thread.block)\(roomBlock(transcript))[REQUEST]\n\(request)\n\nChoose.")
    }

    /// The offer of one further tool call, or nothing when this is the pass that
    /// reads what the hop returned. Absent means the model is never shown a
    /// `next` it could fill, which is what bounds a lookup at two reads.
    private static func oneMoreRead(_ tools: [ChatTool]) -> String {
        guard !tools.isEmpty else { return "" }
        return """


        [ONE MORE READ]
        You may ask for one further tool call instead of answering, and only when the results above name what you need but do not contain it.
        A channel you now have the id of and have not read is the case; so is an issue you now have the key of.
        - Ask for it only when it is the difference between answering and not. If what you already have answers the question, answer it.
        - This is also where a request that named a thing rather than an id gets carried out: the results above hold the id, and the call that acts on it goes here.
        - The person is shown that call and has to allow it, exactly as they would have been for a first choice.
        - Never ask for a call that already appears above, with the same arguments or with different ones. It answered once and the answer is there.
        - This is the last one. What comes back is what you write from, so choose the read that closes the question.
        - Fill its arguments from the results above, never from a guess.

        \(catalogue(tools))
        """
    }

    /// Turn what was gathered into what the card says.
    ///
    /// Both sources arrive together and one answer comes back. They are not
    /// alternatives: "what's the status of onboarding" is half a tracker and
    /// half what the room decided about it three weeks ago, and a card that
    /// picked one would be answering a narrower question than the one asked.
    static func buildLookupAnswer(
        request: String,
        results: [(tool: String, body: String)],
        failures: [(tool: String, message: String)] = [],
        memory: [String],
        thread: AskThread = AskThread(),
        hopTools: [ChatTool] = [],
        transcript: String = "",
        now: Date = Date(),
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let hop = oneMoreRead(hopTools)
        let system = """
        You are answering, in a live meeting, a request somebody typed. You are given what came back for it:
        a connected tool's raw result, earlier discussions from the same project, or both.

        A result from a tool that created something is a thing that now exists — the person already allowed
        it and it has been done. Say what was made and where, in the past tense, and never offer to do it.

        \(nowBlock(now))

        Write one or two sentences. Somebody is going to read this off a small card while a conversation continues around them.

        \(humanProseStyle)

        - Answer the question that was asked. Do not describe the tool, the search, or how many results there were.
        - Lead with the number, name, status or date the question was for. That is the whole reason it was asked out loud.
        - Use both sources when both bear on the question, and say which is which in plain words — "Linear has
          four of seven closed; the team agreed in July to cut the last two". Where they disagree, say so: that
          is the most useful thing this card can ever do.
        - Prefer the tool for anything current — a status, a count, a date. Prefer the earlier discussions for anything decided — why, by whom, what was ruled out.
        - Use only what you were given. Never fill a gap with something plausible; a wrong figure read into a meeting gets repeated.
        - Read every date in the results against [NOW] before calling anything today, upcoming or over.
        - An empty result means the window held nothing, not that the user has nothing. Say what was searched, not what they have.
        - If neither source answers the question, return an empty `text`. Saying nothing is handled; guessing is not.
        - Never apologise, never explain what you could not find, never suggest what to ask instead.
        - A COULD NOT RUN block is a tool that never answered. Say it could not be reached and pass on what it said, in one sentence.
        - Never report it as the product having nothing, and never ask for it again: it will fail the same way.
        - [EARLIER IN THIS ASK BOX] is the conversation this question continues, and it resolves what the question leaves out.
        - A follow-up naming no channel, issue or person means the one from the turn before.
        - [IN THE ROOM] is what is being said right now. It is there to tell you what the question is about — it is
        not a source. Never answer out of the room's own words, and never report something said in the meeting as
        something a tool returned. If only the room answers the question, return an empty `text`: that case is
        handled elsewhere, and an answer built from the meeting wearing a product's mark is the one mistake this
        card must never make.
        - `subject` is what this was read from, in the words a person would recognise it by — an issue key, a channel name, the session an earlier discussion came from. Never a record id, never a URL. Empty when the product's answer carried no such name.
        - `usedTool` is true only when the tool's result is part of your answer. It decides which mark the card shows, so it must not claim a source you did not use.
        - LANGUAGE: write in \(lang).\(hop)

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"next": null, "text": "", "subject": "", "usedTool": false}
        To ask for one more read instead of answering, leave `text` empty and fill `next`:
        {"next": {"tool": "", "arguments": {}}, "text": "", "subject": "", "usedTool": false}
        """

        let user = """
        \(thread.block)\(roomBlock(transcript))[QUESTION]
        \(request)

        \(gathered(results: results, failures: failures, memory: memory))
        Answer it.
        """

        return (system, user)
    }

    /// Everything the answer is allowed to be built from, in the order it is
    /// preferred: what the tools returned, what they could not, and what
    /// earlier sessions said.
    private static func gathered(
        results: [(tool: String, body: String)],
        failures: [(tool: String, message: String)],
        memory: [String]
    ) -> String {
        let ran = results
            .map { "[\($0.tool) RESULT]\n\($0.body.prefix(lookupResultBudget))\n" }
            .joined()
            + failures
            .map { "[\($0.tool) COULD NOT RUN]\n\($0.message)\n" }
            .joined()
        guard !memory.isEmpty else { return ran }
        return ran
            + "[EARLIER IN THIS PROJECT]\n"
            + memory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n"
    }

    /// Enough of a tool result for the answer, and no more. A channel read
    /// comes back with an hour of messages, and the card is two sentences.
    private static let lookupResultBudget = 6_000

    /// What is being said right now, for both calls.
    ///
    /// The two prompts get the same window and the same wording, so a request
    /// cannot be routed against one conversation and phrased against another.
    /// Kept from the end when it overruns: "that ticket" refers to something
    /// said thirty seconds ago, never to the top of the meeting.
    private static func roomBlock(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "[IN THE ROOM]\n\(String(trimmed.suffix(lookupRoomBudget)))\n\n"
    }

    /// Enough of the room to resolve what a request leaves out. Smaller than
    /// the result budget on purpose: this is context for a reference, not
    /// material to answer from, and it is paid for twice per question.
    private static let lookupRoomBudget = 3_000
}
