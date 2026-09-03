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
        "due", "deadline", "planned", "on me", "on my plate", "waiting on me", "what do i have",
        "зробити", "задач", "завдан", "дедлайн", "треба", "потрібно", "заплановано", "на мені", "на моєму боці",
        "сделать", "нужно", "на мне"
    ]

    /// Phrases that make a question about Nod itself — how it captures, what it
    /// keeps, how long — better answered from stated facts than from anything
    /// the user recorded. `AboutNod.grounding` supplies those facts.
    ///
    /// Kept here with the other intents rather than beside the copy it gates:
    /// one place owns "does this question match category X", and a language
    /// added to one table has no reason to be missing from the next.
    private static let aboutNodPhrases = [
        "screenshot", "screen shot", "record my screen", "watch my screen", "see my screen",
        "how long do you keep", "how long is it kept", "how long do you store", "retention",
        "delete my data", "store my data", "keep my data", "privacy", "encrypted",
        "do you remember", "will you remember", "your memory", "soc 2", "soc2", "gdpr", "hipaa",
        "скрін", "скрин", "знімк", "знімок", "екран",
        "запам'ятов", "запамятов", "памʼятаєш", "пам'ятаєш", "памятаєш", "запам'ятаєш", "запамятаєш",
        "зберіга", "збереж", "видалит", "видален", "приватн", "шифр", "безпек",
        "храни", "удали", "запомина", "запомнишь"
    ]

    static func asksAboutNod(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return aboutNodPhrases.contains { lowered.contains($0) }
    }

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

    /// Phrases that make the user's calendar a better answer than any passage.
    private static let schedulePhrases = [
        "calendar", "meeting", "meetings", "call", "calls", "schedule", "scheduled", "booked",
        "free", "busy", "appointment", "agenda", "invite", "event",
        "календар", "зустріч", "мітинг", "дзвінок", "розклад", "вільн", "зайнят", "запланован", "івент",
        "календарь", "встреч", "звонок", "расписание", "свободен", "занят"
    ]

    /// True when the question is about what the user has scheduled. Gates the
    /// calendar block, which otherwise costs a synchronous EventKit read and a
    /// few hundred tokens on every unrelated question.
    /// Whether the question is about what a beat found — the scheduled
    /// briefings Nod runs on its own — or about what the person missed.
    /// Whether the question is about the projects (folders) the person has
    /// organized their sessions into, rather than a specific session.
    static func asksAboutProjects(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if projectPhrases.contains(where: { lowered.contains($0) }) { return true }
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        return words.contains { projectWords.contains($0) }
    }

    private static let projectPhrases = [
        "what projects", "which projects", "my projects",
        "які проєкти", "які проекти", "мої проєкти", "мої проекти"
    ]

    // Plural, not singular: "project" alone is as often a verb ("project the
    // numbers forward") as it is the folder noun; "projects" isn't.
    private static let projectWords: Set<String> = [
        "projects", "folders", "проєкти", "проекти", "папки"
    ]

    static func asksAboutBeats(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if beatPhrases.contains(where: { lowered.contains($0) }) { return true }
        // Whole words only: "beat" is inside "heartbeat", "біт" inside "робіт".
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        return words.contains { beatWords.contains($0) }
    }

    private static let beatPhrases = [
        "what did i miss", "what i missed", "what's new", "whats new", "catch me up", "update me",
        "latest update", "що я пропустив", "що нового", "введи в курс"
    ]

    private static let beatWords: Set<String> = [
        "beat", "beats", "briefing", "briefings", "digest", "біт", "біти", "брифінг", "дайджест"
    ]

    static func asksAboutSchedule(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return schedulePhrases.contains { lowered.contains($0) }
            || SessionTimeRange.mentionsFuture(in: text)
    }
}
