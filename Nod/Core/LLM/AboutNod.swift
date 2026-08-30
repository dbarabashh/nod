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
                    "Only if you switch it on. Ambient context is **off until you turn it on**,",
                    "and with it off nothing about your screen is read, stored or sent."
                ],
                [
                    "With it on, Nod reads the *text* of your frontmost window — the same text a",
                    #"screen reader would — so that "what was I working on this morning" can be"#,
                    "answered from what you had open and not only from what was said out loud."
                ],
                [
                    "Some windows tell macOS almost nothing — chat apps, design tools, and",
                    "anything else that draws itself rather than describing itself.",
                    "For those, and only those,",
                    "Nod captures that one window on your Mac and reads the text out of the",
                    "picture with Apple's on-device recognition, at most once every twenty",
                    "seconds. **The image is never stored and never leaves your Mac** — it exists",
                    "for the length of that one call and only the text survives it.",
                    "There is no video, no screenshot history, nothing image-shaped kept anywhere."
                ],
                [
                    "You decide what it never reads: apps and windows on your blocklist are skipped",
                    "before anything is looked at, not filtered out afterwards.",
                    "You can pause it for a few minutes when a call needs privacy,",
                    "and it turns itself back on so you don't have to remember."
                ],
                [
                    "What it keeps expires on its own — \(ScreenContextDefaults.defaultRetentionDays) days by",
                    "default, and you can set 7 or 30 in Settings.",
                    "A scheduled job on the server deletes expired",
                    "captures even if you never open Nod again, and you can delete the last five",
                    "minutes, the last hour, or everything Nod has ever read, at any time."
                ]
            ])
        ),
        Prepared(
            question: "How is this different from other meeting tools?",
            answer: paragraphs([
                ["Two things."],
                [
                    "Nothing joins your call. Most of them send a bot that appears in the",
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

    /// The facts about Nod itself, for the prompt.
    ///
    /// The prepared answers above are matched on the exact question, which the
    /// first-run pills produce and a person typing rarely does — least of all
    /// in another language. Asked "чи ти робиш скріншоти?" or "will you still
    /// remember this in a month?", Nod had no session to ground on and said so:
    /// *"I cannot reliably name the retention period."* True, and useless, and
    /// about the one subject where a shrug costs the most trust.
    ///
    /// So these travel as grounding rather than as an answer. The model writes
    /// them in whatever language was asked, and it writes them from facts
    /// instead of from what it imagines a Mac app does.
    ///
    /// Every line is traceable: `ScreenTextRecognizer` for the pixel fallback,
    /// `ScreenContextDefaults` for the default and the choices,
    /// `20260723120000_add_screen_observations.sql` for the server-side purge,
    /// and `docs/policies/privacy.md` § 12 for the rest of the table.
    static func grounding(for question: String) -> String? {
        guard QuestionIntent.asksAboutNod(question) else { return nil }
        return facts
    }

    private static let facts = paragraphs([
        ["[ABOUT NOD — answer from this, in the language the question was asked]"],
        [
            "Recording: Nod records the call's audio and the microphone on the user's Mac.",
            "No bot joins the meeting. Transcription is per-chunk through a server-side proxy;",
            "provider keys never ship in the app."
        ],
        [
            "Ambient screen context is OFF until the user turns it on, and nothing about the",
            "screen is read while it is off.",
            "When on, Nod reads the TEXT of the frontmost window through the accessibility",
            "interface. For windows that describe themselves poorly it captures that one",
            "window and runs Apple's on-device text recognition over the picture, at most",
            "once every 20 seconds, and only on macOS 14 or later.",
            "The image is dropped in the same call: nothing image-shaped is stored or sent,",
            "there is no video and no screenshot history. Only the recognised text is kept.",
            "Say this plainly if asked whether Nod takes screenshots — it does capture a",
            "window to read it, and only the text survives. Do not deny the capture."
        ],
        [
            "Screen captures expire on their own: \(ScreenContextDefaults.defaultRetentionDays) days by default,",
            "and the user can choose 7, 14 or 30 in Settings.",
            "A scheduled job on the server deletes expired rows even",
            "if Nod is never opened again. The user can delete the last 5 minutes, 15 minutes,",
            "hour, or everything Nod has ever read, at any time; deleting captures does not",
            "touch sessions or transcripts."
        ],
        [
            "Excluded apps and windows are skipped before anything is read, not filtered",
            "afterwards, and ambient capture can be paused for a few minutes and restores",
            "itself. There is no automatic redaction of card numbers or keys — the blocklist",
            "is the control. Never claim redaction.",
            "Recordings themselves are kept until the user deletes them; a trashed session is",
            "purged after 30 days. Everything is deleted with the account."
        ],
        [
            "Nod holds no SOC 2, HIPAA or ISO certification. Never claim one, and never imply",
            "an audit that has not happened. Data lives in Supabase in eu-west-1.",
            "The macOS app embeds no third-party analytics SDK."
        ]
    ])

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
