import Foundation

/// Finds the people and projects a question names.
///
/// Vector search can't do this: the transcript labels speakers `[Me]`/`[Them]`,
/// so a name the user asks about often appears nowhere in the text that would
/// have to match it. But the name IS on the session, through `meeting_entities`
/// — so the question can be scoped the same deterministic way a date is,
/// instead of hoping the embedding stumbles onto the right meeting.
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

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whole-word match. A substring match would fire "Leo" on "Leonid" and
    /// scope the answer to the wrong person's meetings.
    private static func contains(_ needle: String, in haystack: String) -> Bool {
        guard let range = haystack.range(of: needle) else { return false }
        let beforeIsBoundary = range.lowerBound == haystack.startIndex
            || !haystack[haystack.index(before: range.lowerBound)].isLetter
        let afterIsBoundary = range.upperBound == haystack.endIndex
            || !haystack[range.upperBound].isLetter
        return beforeIsBoundary && afterIsBoundary
    }
}
