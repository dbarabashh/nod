import Foundation

/// Finds the people and projects a piece of text names.
///
/// Vector search can't do this: the transcript labels speakers `[Me]`/`[Them]`,
/// so a name the user asks about often appears nowhere in the text that would
/// have to match it. But the name IS on the session, through `meeting_entities`
/// — so the question can be scoped the same deterministic way a date is,
/// instead of hoping the embedding stumbles onto the right meeting.
///
/// Two ways to ask, and the difference is a decision rather than an accident, so
/// they live beside each other:
///
/// - `matched(names:in:)` wants the name as a phrase, whole-word. Right for a
///   question somebody typed, where "Anna Kovalenko" was typed on purpose and
///   scoping to the wrong Anna is the failure to avoid.
/// - `names(_:spokenIn:)` wants every content word present, in any order. Right
///   for a transcript, where a project gets declined, inverted and split across
///   a clause, and "the companion app for mobile" is the same subject as
///   "Mobile Companion".
enum EntityMatcher {
    /// Below this a "name" matches too much — initials, "AI", a two-letter
    /// project code that appears inside ordinary words.
    private static let minimumNameLength = 3

    /// Names present in the question, longest first so "Anna Kovalenko" wins
    /// over "Anna" when both are entities.
    static func matched(names: [String], in question: String) -> [String] {
        let haystack = normalized(question)
        guard !haystack.isEmpty else { return [] }
        // Filter first: the sort exists to order the matches, and there are
        // usually none or one of those against a list of every entity.
        return names
            .filter { $0.count >= minimumNameLength && contains(normalized($0), in: haystack) }
            .sorted { $0.count > $1.count }
    }

    /// Whether the words of a name are all present in what was said.
    ///
    /// An empty `tokens` never matches: a name that survives normalisation as
    /// nothing — an acronym, a two-letter code — would otherwise be present in
    /// every sentence, which is the same trap `minimumNameLength` closes for the
    /// phrase form.
    static func names(_ tokens: Set<String>, spokenIn said: Set<String>) -> Bool {
        !tokens.isEmpty && tokens.isSubset(of: said)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whole-word match. A substring match would fire "Leo" on "Leonid" and
    /// scope the answer to the wrong person's meetings.
    ///
    /// Every occurrence is tried, not only the first: "Leonid opened it, Leo
    /// approved" names Leo, and stopping at the first hit said it did not.
    private static func contains(_ needle: String, in haystack: String) -> Bool {
        var searched = haystack.startIndex ..< haystack.endIndex
        while let range = haystack.range(of: needle, range: searched) {
            let beforeIsBoundary = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterIsBoundary = range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
            if beforeIsBoundary, afterIsBoundary { return true }
            searched = haystack.index(after: range.lowerBound) ..< haystack.endIndex
        }
        return false
    }
}
