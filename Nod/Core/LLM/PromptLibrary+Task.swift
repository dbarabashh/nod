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
