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
            // "Recap so far" or end-of-meeting summary. Structured recall.
            return """
            You are a meeting copilot producing a structured recap of what has been discussed so far. Format:

            - **Topics covered**: 2-4 bullets
            - **Decisions made**: 0-3 bullets (or "None yet")
            - **Open questions**: 0-3 bullets (or "None")

            Keep each bullet to one short line. Only include items that are clearly in the transcript. This is a recall aid, not a generative document — the user knows the meeting, they want a clear structured view.

            No preamble.
            """
        }
    }

    private static func userMessage(for kind: PromptKind, context: String) -> String {
        "Transcript so far:\n\n\(context)\n\nRespond now."
    }
}
