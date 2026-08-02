import Foundation

/// What the chat says while it works.
///
/// The wait is real: a question crosses query prep, a vector search over the
/// whole corpus, the open-task list and the screen record before a token is
/// written. "Searching your sessions…" held still through all of it and named
/// only the first of the four — so a long wait read as a stall, and the one
/// thing the user was told was the least of what happened.
enum ChatThinking {
    /// Retrieval, in the order it actually runs. The last line holds if the
    /// search runs longer than the script.
    static let searching: [String] = [
        "Reading your question…",
        "Searching everything you've captured…",
        "Sessions, tasks, and what was on your screen…",
        "Following a few more threads…",
        "Pulling the details together…"
    ]

    static let writing: [String] = [
        "Piecing it together…",
        "Writing your answer…"
    ]

    /// What the retrieval actually came back with. Counting it out loud is the
    /// point — "reading 6 sessions" is the moment the answer stops looking like
    /// a chatbot's and starts looking like the user's own memory.
    static func reading(sessions: Int, apps: Int) -> String {
        switch (sessions, apps) {
        case (0, 0):
            "Nothing matched — answering from what I have…"
        case (0, _):
            "Reading what was on your screen…"
        case (_, 0):
            "Reading \(counted(sessions, "session"))…"
        default:
            "Reading \(counted(sessions, "session")) and \(counted(apps, "app"))…"
        }
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
