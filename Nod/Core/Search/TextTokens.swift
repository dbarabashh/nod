import Foundation

/// The one word-splitting rule the app matches on.
///
/// Blocklist matching, screen-context search terms and recap-phrase detection
/// each need "the words in this string, lowercased" — and all three carry
/// Cyrillic, where the boundary rule is the difference between matching and
/// not. Written three times it is three chances to diverge on a rule none of
/// the three can be right about alone.
enum TextTokens {
    /// Lowercased runs of letters and digits. Punctuation, whitespace and
    /// symbols are separators; empty runs are dropped.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The words worth matching on: long enough to carry meaning, and not one
    /// of the caller's own stopwords.
    ///
    /// The stopword set stays with the caller — what separates nothing differs
    /// between searching a screen and finding a promise — but the floor and the
    /// split live here, because those are the parts that must not drift.
    /// In the order they were said, because a caller that takes the first few
    /// as search terms is taking the ones the sentence led with.
    static func contentWords(
        in text: String,
        longerThan minimum: Int,
        excluding stopWords: Set<String>
    ) -> [String] {
        words(in: text).filter { $0.count >= minimum && !stopWords.contains($0) }
    }

    /// Short all-caps words — "YC", "PR", "NOD-7"'s "NOD" — lowercased. They
    /// fall under any sensible length floor and are the most specific thing a
    /// question carries.
    static func acronyms(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { (2 ... 5).contains($0.count) && $0.allSatisfy { $0.isUppercase || $0.isNumber } && $0.contains(where: \.isLetter) }
            .map { $0.lowercased() }
    }
}
