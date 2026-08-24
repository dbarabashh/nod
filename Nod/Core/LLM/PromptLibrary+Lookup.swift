import Foundation

/// Answering a question the room asked out loud, out of a connected tool.
///
/// Two calls rather than a tool loop, and that is the point. The chat can take
/// as many rounds as an answer needs because somebody is sitting and waiting
/// for it. This runs while people are mid-sentence: a second round is a second
/// of silence, and an answer that arrives after the conversation moved on is
/// worse than none. So the model chooses once, and writes once.
extension PromptLibrary {
    struct LookupChoice: Decodable {
        /// The tool to run, or nil when none of them answers this.
        let tool: String?
        /// Arguments for it, as the schema describes them.
        let arguments: [String: String]?
    }

    struct LookupAnswer: Decodable {
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

    /// Pick the one read tool that answers the request.
    static func buildLookupRouting(request: String, tools: [ChatTool]) -> (system: String, user: String) {
        let catalogue = tools.map { tool in
            let args = tool.parameters.properties
                .map { "\($0.key): \($0.value.description)" }
                .sorted()
                .joined(separator: "; ")
            let required = tool.parameters.required.joined(separator: ", ")
            return "- \(tool.name): \(tool.description)\n  arguments — \(args)\n  required — \(required.isEmpty ? "none" : required)"
        }.joined(separator: "\n")

        let system = """
        Somebody in a meeting asked Nod a question out loud. Choose the one tool that answers it, and the arguments to run it with.

        - Choose nothing rather than something close. A wrong lookup wastes the moment it was asked in, and the person will simply ask again.
        - Only fill an argument the request actually supports. Never invent an id, a channel, a date or a name that was not said.
        - If a tool needs an id the request does not give, choose the tool that finds it by name instead. If there is none, choose nothing.
        - The request was spoken, so it arrives punctuated by a transcriber and may be clipped. Read it for intent, not for grammar.

        [TOOLS]
        \(catalogue.isEmpty ? "None." : catalogue)

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"tool": "", "arguments": {}}
        Use {"tool": null, "arguments": null} when nothing here answers the request.
        """

        return (system, "[REQUEST]\n\(request)\n\nChoose.")
    }

    /// Turn what was gathered into what the card says.
    ///
    /// Both sources arrive together and one answer comes back. They are not
    /// alternatives: "what's the status of onboarding" is half a tracker and
    /// half what the room decided about it three weeks ago, and a card that
    /// picked one would be answering a narrower question than the one asked.
    static func buildLookupAnswer(
        request: String,
        toolName: String?,
        result: String?,
        memory: [String],
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are answering, in a live meeting, a question somebody asked out loud. You are given what was
        gathered for it: a connected tool's raw result, earlier discussions from the same project, or both.

        Write one or two sentences. Somebody is going to read this off a small card while a conversation continues around them.

        \(humanProseStyle)

        - Answer the question that was asked. Do not describe the tool, the search, or how many results there were.
        - Lead with the number, name, status or date the question was for. That is the whole reason it was asked out loud.
        - Use both sources when both bear on the question, and say which is which in plain words — "Linear has
          four of seven closed; the team agreed in July to cut the last two". Where they disagree, say so: that
          is the most useful thing this card can ever do.
        - Prefer the tool for anything current — a status, a count, a date. Prefer the earlier discussions for anything decided — why, by whom, what was ruled out.
        - Use only what you were given. Never fill a gap with something plausible; a wrong figure read into a meeting gets repeated.
        - If neither source answers the question, return an empty `text`. Saying nothing is handled; guessing is not.
        - Never apologise, never explain what you could not find, never suggest what to ask instead.
        - `subject` is what this was read from — an issue key, a channel name, or the session an earlier discussion came from — copied from what you were given, or empty.
        - `usedTool` is true only when the tool's result is part of your answer. It decides which mark the card shows, so it must not claim a source you did not use.
        - LANGUAGE: write in \(lang).

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"text": "", "subject": "", "usedTool": false}
        """

        let tool = result.map { "[\(toolName ?? "TOOL") RESULT]\n\($0.prefix(lookupResultBudget))\n" } ?? ""
        let earlier = memory.isEmpty
            ? ""
            : "[EARLIER IN THIS PROJECT]\n"
            + memory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n"

        let user = """
        [QUESTION]
        \(request)

        \(tool)\(earlier)
        Answer it.
        """

        return (system, user)
    }

    /// Enough of a tool result for the answer, and no more. A channel read
    /// comes back with an hour of messages, and the card is two sentences.
    private static let lookupResultBudget = 6_000
}
