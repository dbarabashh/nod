import Foundation

/// What the chat says while it works.
///
/// The wait is real: a question crosses query prep, a vector search over the
/// whole corpus, the open-task list and the screen record before a token is
/// written. "Searching your sessions…" held still through all of it and named
/// only the first of the four — so a long wait read as a stall, and the one
/// thing the user was told was the least of what happened.
enum ChatThinking {
    /// Before anything has been decided.
    ///
    /// Its own script rather than the first line of `searching`, because a
    /// script keeps walking: hand over `searching` while query prep is still
    /// running and 1.6 seconds later the surface claims to be searching every
    /// session — on a question that may turn out to need no retrieval at all,
    /// and often does. Nothing is promised until something is known.
    static let preparing: [String] = [
        "Reading your question…"
    ]

    /// Retrieval, in the order it actually runs. The last line holds if the
    /// search runs longer than the script. Handed over only once routing has
    /// decided there is something to search.
    static let searching: [String] = [
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

    /// The wait before a self-contained action. Says nothing about sessions:
    /// on this path none were read, and claiming otherwise is the kind of small
    /// lie that teaches people to distrust the whole surface.
    static let acting: [String] = [
        "Working on it…"
    ]

    /// The model has the question and is deciding whether to reach for a
    /// connected product. Nothing is being written yet, and saying "writing"
    /// here is the same small lie as claiming sessions were read.
    /// One session, already loaded — the per-session chat has nothing to search
    /// for and nothing to route, so it says what it is actually doing.
    static let reviewing: [String] = [
        "Thinking…",
        "Reviewing the transcript…",
        "Putting it together…"
    ]

    static let deciding: [String] = [
        "Thinking it through…"
    ]

    /// Shown while a tool call is in flight. Names the product rather than the
    /// action: the user approved the action a moment ago and already knows what
    /// it was — what they can't see is that the wait is now somebody else's
    /// server.
    static func calling(_ provider: IntegrationProvider) -> [String] {
        [
            "Asking \(provider.displayName)…",
            "Waiting on \(provider.displayName)…"
        ]
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
