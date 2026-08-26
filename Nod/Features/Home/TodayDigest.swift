import Foundation

/// Which recap sections hold something the room left open, and which hold what
/// it settled.
///
/// Matched on signal words rather than exact headings, because the recap model
/// writes those titles in the user's output language. Pure and table-driven for
/// the same reason `QuestionIntent` is: there is no model call here, and a
/// section is classified the same way on every run.
enum TodayDigest {
    /// Section titles are written by the recap model in the user's output
    /// language, so the match is on the signal words both languages settle on
    /// ("Open questions" / "Відкриті питання"). A plain "Questions" section —
    /// what an interview recap produces — is deliberately NOT a signal: those
    /// are questions that were asked and answered, not left open.
    static func leavesSomethingOpen(_ sectionTitle: String) -> Bool {
        let title = sectionTitle.lowercased()
        return openSignals.contains { title.contains($0) }
    }

    /// The mirror of `leavesSomethingOpen`: a section holding what the room
    /// settled. Matched the same way and for the same reason — the model writes
    /// these titles in the user's language, so the signal has to be the word,
    /// not the exact heading.
    static func settlesSomething(_ sectionTitle: String) -> Bool {
        let title = sectionTitle.lowercased()
        return decisionSignals.contains { title.contains($0) }
    }

    private static let decisionSignals = [
        "decision", "decided", "agreed", "agreement", "resolved",
        "рішенн", "вирішен", "домовил", "погодж"
    ]

    private static let openSignals = [
        "open question", "open thread", "open item", "unresolved", "undecided",
        "pending", "to decide", "risk", "blocker",
        "відкрит", "невиріш", "нерозв", "ризик"
    ]
}
