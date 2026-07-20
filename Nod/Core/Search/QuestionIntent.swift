import Foundation

/// Reads intent out of the user's question. Questions arrive in whatever
/// language the user speaks — the transcript's language is irrelevant here — so
/// every table carries EN/UK/RU, and adding a language is one edit in one file
/// rather than three types across two layers.
///
/// Pure, so the whole table is unit-testable.
enum QuestionIntent {
    /// Interrogatives that open a question. A bare one ("how", "що") stays a
    /// search: one word in, the user is as likely to be typing a name.
    private static let interrogatives = [
        "what", "why", "how", "when", "who", "where", "which", "did", "do", "does", "is", "are", "can", "should",
        "summarise", "summarize",
        "що", "чому", "як", "коли", "хто", "де", "який", "яка", "які", "скільки", "чи", "розкажи", "підсумуй",
        "что", "почему", "как", "когда", "кто", "где", "какой", "какая", "какие", "сколько", "расскажи"
    ]

    /// Phrases that make the open task list a better answer than any passage.
    private static let taskPhrases = [
        "to do", "todo", "to-do", "task", "action item", "should i do", "need to do", "outstanding", "follow up",
        "due", "deadline", "planned",
        "зробити", "задач", "завдан", "дедлайн", "треба", "потрібно", "заплановано",
        "сделать", "нужно"
    ]

    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return interrogatives.contains(firstWord) && trimmed.contains(" ")
    }

    /// True when the question is about what's outstanding — including anything
    /// pointing at days ahead, since "what's next week" asks about commitments
    /// already made.
    static func asksAboutTasks(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return SessionTimeRange.mentionsFuture(in: text) || taskPhrases.contains { lowered.contains($0) }
    }
}
