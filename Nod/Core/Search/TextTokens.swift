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
}
