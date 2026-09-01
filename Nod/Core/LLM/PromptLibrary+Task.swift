import Foundation

/// Turning one action item into a task somebody else could pick up.
///
/// The item's own text is a note to self, written by a pass that was listening
/// to a sentence — "send Anna the pricing deck". A tracker is read by a person
/// with no memory of the call, possibly weeks later, so what belongs there is
/// the same commitment plus the context the room had and the ticket wouldn't:
/// which deck, why it came up, what was decided about it.
extension PromptLibrary {
    static func buildTaskDraft(
        item: String,
        deadline: String?,
        meetingTitle: String,
        meetingDate: String,
        excerpt: String,
        summary: String,
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are writing one task in an issue tracker, from a commitment made in a meeting.

        Write a title and a description.

        TITLE: one line, imperative, under 100 characters. What has to be done, not what was said. No ticket prefixes, no "Task:", no trailing period. Name the concrete object where the room named one ("Send Anna the Q3 pricing deck", not "Send the deck").

        DESCRIPTION: 1-3 short paragraphs of plain prose, or a few bullets if the work genuinely has parts. Cover only what the reader needs and the transcript actually supports:
        - what was agreed, and by whom if the excerpt names them
        - why it came up — the problem behind the request
        - any specifics said out loud: names, numbers, dates, links, tools
        End with a line "Discussed in <meeting title>, <date>." and nothing after it.

        \(humanProseStyle)

        - Ground every claim in the excerpt or the summary. Never invent a name, a number, a deadline or a decision that isn't there.
        - If the excerpt is thin, write a shorter description rather than padding it. One accurate sentence beats three vague ones.
        - Don't restate the title as the first line of the description.
        - Don't address the reader ("you should"), and don't write meta ("This task is about…").
        - LANGUAGE: write in \(lang) unless the meeting was clearly in another language, in which case match the meeting.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"title": "", "description": ""}
        """

        let due = deadline.map { "[DEADLINE AS SPOKEN]\n\($0)\n\n" } ?? ""
        let user = """
        [COMMITMENT]
        \(item)

        \(due)[MEETING]
        \(meetingTitle) — \(meetingDate)

        [WHAT WAS SAID AROUND IT]
        \(excerpt.isEmpty ? "Not available — work from the summary." : excerpt)

        [MEETING SUMMARY]
        \(summary.isEmpty ? "Not available." : summary)

        Write the task.
        """
        return (system, user)
    }

    struct TaskDraftResult: Decodable {
        let title: String
        let description: String
    }
}

extension PromptLibrary {
    /// Follow-up drafts from an agent's own brief: work the brief surfaced that
    /// this meeting's to-do extraction did not already catch. Restraint is the
    /// bar, exactly as it is for the distiller — most briefs owe nothing, and
    /// every returned row costs the user a decision on the review card.
    static func buildAgentDrafts(
        brief: String,
        meetingTitle: String,
        existingTitles: [String],
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You read a work brief and decide whether it surfaced any task worth preparing that is NOT already on the meeting's own to-do list. Almost always the answer is none.

        A task qualifies only when ALL hold:
        - the brief states it as real outstanding work — owed, blocked, or promised. Not a theme, not "consider", not advice.
        - it is not already covered by an EXISTING item, in any wording.
        - it is concrete enough that a person reading only the title knows what to do.

        Each draft:
        - "title": one line, imperative, in \(lang), ≤ 120 characters
        - "details": one sentence of context from the brief, in \(lang), or ""

        [OUTPUT] ONLY this JSON, no prose, no code fence — an empty list is the expected answer:
        {"drafts": []}
        Never more than 3.
        """
        let existing = existingTitles.isEmpty
            ? "(none)"
            : existingTitles.map { "- \($0)" }.joined(separator: "\n")
        let user = """
        [MEETING]
        \(meetingTitle)

        [EXISTING ITEMS]
        \(existing)

        [BRIEF]
        \(brief)
        """
        return (system, user)
    }

    struct AgentDraftsResult: Decodable {
        struct Draft: Decodable {
            let title: String
            let details: String?
        }

        let drafts: [Draft]
    }
}
