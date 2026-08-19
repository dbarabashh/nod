import Foundation

/// What Nod says when the question is about Nod.
///
/// A first run has nothing recorded, so the openers that name last week's
/// meeting have nothing to name — and the four generic ones ("what did I
/// promise?") are answered with "I don't have anything on that yet", which is
/// the worst possible first impression of a memory product. The empty state
/// asks about the product instead.
///
/// The answers are written here rather than left to the model. A question
/// about Nod has no session to ground on, so the model would be answering from
/// whatever it happens to believe about a macOS app it has never seen — and
/// getting the pitch wrong in the one conversation that decides whether
/// somebody records anything. Every claim below is traceable to code in this
/// repo; nothing here describes a feature that does not exist.
enum AboutNod {
    struct Prepared: Equatable {
        let question: String
        let answer: String
    }

    static let prepared: [Prepared] = [
        Prepared(
            question: "What can Nod do?",
            answer: paragraphs([
                [
                    "I record what you're in — the call's audio and your microphone, straight off this Mac,",
                    "with no bot joining the meeting — and transcribe it as it happens."
                ],
                [
                    "While a session is running you can ask about it in the bar itself,",
                    "without waiting for it to end — what was just agreed, what a number was,",
                    "what somebody's objection actually was."
                ],
                [
                    "When it ends you get a recap: what was decided, what's still open,",
                    "and what somebody committed to.",
                    "Those commitments become action items you can tick off."
                ],
                [
                    "After that the recordings are memory. You can ask across all of them here —",
                    #""what did I promise?", "what's still unresolved?" —"#,
                    "and the answer cites the sessions it came from, so you can check it."
                ],
                [
                    "Nod can also reach into the tools you connect — reading what is tracked there,",
                    "and filing into them when you ask.",
                    "It asks before every one of those, and shows you what it is about to send."
                ]
            ])
        ),
        Prepared(
            question: "How do I get set up?",
            answer: paragraphs([
                ["Two permissions, and then a keystroke."],
                [
                    "Grant the microphone and screen-recording permissions when Nod asks.",
                    "Screen recording is how macOS lets an app hear the *other* side of a call —",
                    "without it you'd only record yourself, and nothing is captured visually either way."
                ],
                [
                    "Out of the box, **⌘⇧H** shows and hides the capture panel and **⌘⇧K** opens search and ask",
                    "from anywhere, without bringing the main window forward.",
                    "Both are yours to change in Settings."
                ],
                [
                    "On a Mac with a notch the panel hangs from the cut-out and fills space nothing else uses.",
                    "Without one — and on any external display, which has no cut-out to hang from —",
                    "it's a floating card you can drag where you like;",
                    "Nod remembers where you left it on each display.",
                    "You can pick either in Settings."
                ],
                [
                    "Optionally, connect your tools in Settings,",
                    "so answers here can reach the things you actually track."
                ]
            ])
        ),
        Prepared(
            question: "Does Nod watch my screen?",
            answer: paragraphs([
                [
                    "**No screenshots. Ever.** Nod takes no pictures of your screen, and there is no",
                    "code in it that can — nothing visual is captured, stored or sent anywhere."
                ],
                [
                    "There is an optional feature called ambient context, and it is **off until you turn it on**.",
                    "When it is on, Nod reads the *text* of your frontmost window — the same text a",
                    "screen reader would — so that \"what was I working on this morning\" can be answered",
                    "from what you had open and not only from what was said out loud."
                ],
                [
                    "You decide what it never reads: apps and windows on your blocklist are skipped",
                    "before anything is looked at, not filtered out afterwards.",
                    "You can pause it for a few minutes when a call needs privacy,",
                    "and it turns itself back on so you don't have to remember."
                ],
                [
                    "What it does keep expires on its own. Every captured line carries an expiry",
                    "and is deleted server-side when it passes, and you can wipe the lot at any time."
                ]
            ])
        ),
        Prepared(
            question: "How is this different from other AI note-takers?",
            answer: paragraphs([
                ["Two things."],
                [
                    "Nothing joins your call. Most note-takers send a bot that appears in the",
                    "participant list and needs a calendar invite.",
                    "Nod records the audio on your Mac, so it works on any call —",
                    "including the ones that were never scheduled."
                ],
                [
                    "And a recording doesn't end at its own notes.",
                    "Every session becomes part of one memory you can ask across,",
                    #"so "what did we decide about pricing" reaches every conversation where"#,
                    "pricing came up, not just the meeting you happen to have open."
                ]
            ])
        )
    ]

    /// Sentences to a paragraph, paragraphs to an answer. Written this way so
    /// a paragraph of prose isn't one 300-character source line — the same
    /// shape the prompt rules use.
    private static func paragraphs(_ blocks: [[String]]) -> String {
        blocks.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// The prepared answer to `question`, when it is one of ours.
    ///
    /// Matched on the exact question, normalised for case, spacing and the
    /// trailing question mark — nothing looser. "What can Nod do about the
    /// pricing decision?" is a question about the user's sessions that happens
    /// to contain ours, and answering it with the pitch would be worse than
    /// not recognising it at all.
    static func answer(to question: String) -> String? {
        let asked = normalised(question)
        return prepared.first { normalised($0.question) == asked }?.answer
    }

    static var questions: [String] {
        prepared.map(\.question)
    }

    private static func normalised(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
