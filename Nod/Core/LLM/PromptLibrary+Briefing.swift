import Foundation

/// The day, told rather than listed.
///
/// The list under this is already on the screen, and a person who wanted a list
/// would read that. What the model is asked for is the thing the list cannot
/// be: somebody who has looked at all of it saying what today is, which part of
/// it is load-bearing, and what would go wrong if it slipped.
///
/// It writes about a set of items it did not choose. Every row was assembled
/// from the account's own data before this call, and a briefing that named a
/// fifth meeting or moved a deadline would be a briefing nobody trusts twice.
extension PromptLibrary {
    /// The day as lines of text, grouped the way the screen groups it. One
    /// value rather than four arrays so the call site cannot pass them in the
    /// wrong order — they are all `[String]` and nothing else would notice.
    struct DailyBriefingItems {
        let ahead: [String]
        let owed: [String]
        let loose: [String]
        let onScreen: [String]
    }

    /// What the model sends back. Declared beside the prompt that names the
    /// key, the way every other prompt here declares its own result — split
    /// across the two layers, a rename passes both compilers and fails at run
    /// time.
    struct DailyBriefingResult: Decodable {
        let brief: String
    }

    static func buildDailyBriefing(
        name: String?,
        dayLabel: String,
        clock: String,
        items: DailyBriefingItems,
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are writing one person's daily briefing in their meeting-notes app. You are given the exact list of items that is drawn under what you write.

        Write three or four sentences. Not a list, not headings — prose, the way a chief of staff tells somebody their day in the doorway.

        Cover, in this order and only where there is something to say:
        1. What today is made of. The shape, not the inventory — "three calls, all before lunch" rather than naming each.
        2. The one thing that is load-bearing: the nearest fixed commitment, or the deadline that is closest, or the thing that has been open longest. Name it specifically.
        3. What is carried over that they may not be thinking about — an unresolved question, an old commitment.

        \(humanProseStyle)

        - Address them directly as "you". Never in the third person, never by name in the body — the greeting above already says it.
        - Be specific where the list is specific. Use the real title, the real time, the real deadline. Vague prose about "several items" is what makes a briefing skippable.
        - Use only the items given. Never add a meeting, a task, a name, a number or a time that is not in the list.
        - Never count wrong. Any number you write has to match the list you were handed.
        - An empty group is not worth a sentence. Write fewer sentences instead.
        - Don't advise, don't encourage, don't wish them luck, don't tell them to prioritise. Say what is true and stop.
        - Don't name the app, don't refer to the briefing itself, and don't open with "Today".
        - You may be shown what they have had on screen. Use it only to say which piece of work something belongs to,
          and only when a window title plainly names it. At most one such connection, and none if none is obvious.
        - Never say something has NOT been worked on. Screen context is off by default, kept briefly, and covers one Mac — an item missing from it means nothing at all.
        - Never list what was on screen, never name an app they did not need named, never quote anything from a window.
        - LANGUAGE: write in \(lang).

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"brief": ""}
        """

        let user = """
        [NOW]
        \(dayLabel), \(clock)

        \(block("STILL AHEAD TODAY", items: items.ahead, empty: "Nothing left on the calendar."))
        \(block("OPEN COMMITMENTS", items: items.owed, empty: "None outstanding."))
        \(block("LEFT UNRESOLVED RECENTLY", items: items.loose, empty: "Nothing open."))
        \(items.onScreen.isEmpty ? "" : block(screenHeader, items: items.onScreen, empty: ""))
        Write the briefing.
        """

        return (system, user)
    }

    private static let screenHeader = "ON SCREEN IN THE LAST DAY — context only, never something to report back"

    private static func block(_ header: String, items: [String], empty: String) -> String {
        guard !items.isEmpty else { return "[\(header)]\n\(empty)\n" }
        return "[\(header)]\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }
}
