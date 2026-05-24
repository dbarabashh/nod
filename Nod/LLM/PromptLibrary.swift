import Foundation

enum PromptKind {
    case hero          // "Catch me up"
    case smartReply    // "Key points"
    case followUp      // "Suggest follow-up questions"
    case summary       // "Recap so far" / "Meeting Summary"

    init?(rawLabel: String) {
        switch rawLabel {
        case "hero": self = .hero
        case "Key points": self = .smartReply
        case "Suggest follow-up questions": self = .followUp
        case "Recap so far": self = .summary
        default: return nil
        }
    }
}

struct PromptLibrary {
    static func build(
        kind: PromptKind,
        transcript: String,
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let context = transcript.isEmpty
            ? "(No transcript captured yet.)"
            : transcript
        let baseSystem = system(for: kind)
        let langDirective = "\n\nIMPORTANT: Respond in \(language.promptName). Even if the transcript contains other languages, output your reply in \(language.promptName)."
        return (baseSystem + langDirective, userMessage(for: kind, context: context))
    }

    private static func system(for kind: PromptKind) -> String {
        switch kind {
        case .hero:
            // "Catch me up" — recall, not suggestion. We give the user a tight
            // snapshot of where the conversation IS, not what they should say.
            return """
            You are a memory aid for a meeting that is currently in progress. The user just rejoined or lost the thread of the conversation. Based on the transcript, give them a concise 2-3 sentence catch-up: what's the current topic, who said what about it, and where the discussion is right now.

            Rules:
            - DO NOT suggest a reply for the user to say.
            - DO NOT generate a message in the user's voice.
            - DO NOT use phrases like "you should say" or "you could respond".
            - Just describe what's happening in the meeting. The user reads it and decides for themselves what to do.

            No preamble.
            """
        case .smartReply:
            // "Key points" — extract decisions/facts/questions surfaced so far.
            return """
            You are a memory aid for an ongoing meeting. Pull out the 3-5 most important points that have actually been discussed so far — decisions, key facts shared, or questions raised. Use a short bulleted list, each bullet one tight line.

            Rules:
            - Only summarize what has actually been said in the transcript.
            - DO NOT invent points that weren't raised.
            - DO NOT suggest replies or actions for the user.
            - If the transcript is too thin to extract meaningful points, say so in one line.

            No preamble.
            """
        case .followUp:
            // Distinct from "suggest a reply": these are clarifying QUESTIONS
            // the user could choose to ask, designed to surface missing info.
            return """
            You are helping the user think of useful clarifying questions to ask in this meeting. Based on what's been discussed, suggest 2-3 specific follow-up questions the user could consider asking — questions that would surface missing information, clarify a vague point, or push the discussion forward.

            Rules:
            - Output as a short bulleted list of questions.
            - These are options for the user to CONSIDER, not scripted lines to read verbatim.
            - DO NOT prefix with "You should ask" or similar.
            - Each question should be specific to something actually said in the transcript.

            No preamble.
            """
        case .summary:
            // End-of-meeting recap. The aha-moment artefact: user just left
            // the call, may have lost track of a decision or two, scans this
            // and recovers what slipped past. Substantive but tight — not a
            // tweet, not a transcript.
            return """
            You are a meeting copilot producing the recap of a meeting that just ended. The user was on the call and may have forgotten details — your job is to give them a clear, useful read-out so nothing important slips through.

            Format using markdown, with each section header bolded on its own line, followed by bullets below it:

            **Topics covered**
            - 4-7 bullets. Each bullet: what was discussed (one short sentence) + a brief follow-up sentence with context, who raised it, or what was said. Aim for substance over labels.

            **Decisions made**
            - 0-5 bullets. For each: the decision, who owns it, the timeline if mentioned. If nothing was decided, write a single line: "None yet."

            **Open questions**
            - 0-5 bullets. Unanswered questions, blockers, items deferred. If none, write a single line: "None."

            Rules:
            - Ground every bullet in something actually said in the transcript. Do NOT invent details or pad.
            - Be specific (use names, numbers, dates from the transcript) rather than generic ("we discussed X").
            - Keep each bullet readable in two seconds — aim for 1-2 sentences, no walls of text.
            - DO NOT add preamble, conclusion, or meta-commentary. Just the three sections.
            """
        }
    }

    private static func userMessage(for kind: PromptKind, context: String) -> String {
        "Transcript so far:\n\n\(context)\n\nRespond now."
    }

    // MARK: - Title generation

    /// Generates a short, calendar-event-style title for a completed meeting
    /// based on its recap. Used by HistoryView so users see "Q3 pricing
    /// alignment" instead of "Meeting on 23 May 2026, 19:23". Issue #14.
    static func buildTitle(
        summary: String,
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let system = """
        You are generating a short title for a meeting based on its recap. The title should read like a calendar-event title — what someone would label this meeting on their calendar.

        Rules:
        - 4-7 words total. Hard limit at 7 words.
        - Specific to what the meeting was actually about (e.g. "Q3 pricing alignment" not "Team meeting"). Pull a concrete project name, topic, or decision from the recap.
        - No quotes, no markdown, no trailing punctuation.
        - No preamble like "Title:" — just the title text on a single line.

        IMPORTANT: Respond in \(language.promptName). Even if the recap contains other languages, output the title in \(language.promptName).
        """

        let user = "Meeting recap:\n\n\(summary)\n\nGenerate the title now."

        return (system, user)
    }

    // MARK: - AI-assisted summary editing

    /// Builds the prompt for "Ask AI to edit this recap" — the small chat-style
    /// input under the summary card. Given the current recap text + a natural-
    /// language instruction, produce an updated recap.
    static func buildSummaryEdit(
        currentSummary: String,
        instruction: String,
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let system = """
        You are editing the user's meeting recap. They will give you the current recap and a single edit instruction.

        Apply the instruction precisely. Preserve the existing structure (the **Topics covered**, **Decisions made**, **Open questions** sections with their markdown bold headers) and keep all content the user did not ask you to change. Do not invent details that aren't in the current recap or supported by it.

        Output ONLY the full updated recap text — no preamble, no closing remark, no explanation of what you changed. Use the same markdown format as the input (bold section headers on their own line, bulleted items below).

        IMPORTANT: Respond in \(language.promptName). Output the recap in \(language.promptName) even if the instruction is given in another language.
        """

        let user = """
        Current recap:

        \(currentSummary)

        Edit instruction: \(instruction)

        Output the updated recap now.
        """

        return (system, user)
    }
}
