import Foundation

/// Whether two action items say the same thing — the check `saveExtracted` makes
/// when deciding whether the recap has restated something the live pass already
/// wrote down.
///
/// Client-side and deliberately simple: no embeddings, no backend, just
/// normalized token overlap. Conservative on purpose — a false match silently
/// loses one of the recap's actions, so the threshold and shared-token floor
/// err toward saying no.
enum ActionItemDedup {
    /// Words shorter than this are dropped as low-signal ("to", "a", and most
    /// inflectional noise) before comparing.
    private static let minTokenLength = 3
    /// Common function words that clear `minTokenLength` but carry no task
    /// signal — dropped so two unrelated tasks ("Ask the team" / "Ask the
    /// client") don't score a shared-token match on "the".
    private static let stopwords: Set<String> = [
        "the", "and", "for", "but", "with", "you", "your", "our", "are", "was",
        "were", "this", "that", "from", "into", "per", "via", "out", "off", "its",
        "has", "have", "will", "their", "them", "they"
    ]
    /// Minimum overlapping meaningful tokens for a pair to qualify — guards
    /// against two short tasks scoring high on a single shared word.
    private static let minSharedTokens = 2

    /// Whether two texts describe the same task *within one meeting* — the
    /// question `saveExtracted` asks when deciding whether the recap has just
    /// restated something the live pass already wrote down.
    ///
    /// Asymmetric in what it tolerates: a false match here silently loses one of
    /// the recap's actions, where a miss only costs a duplicate row. Identical wording is the
    /// common case — the same sentence read twice — so it is checked outright,
    /// below the token floor that would otherwise reject a two-word task.
    static func same(_ a: String, _ b: String) -> Bool {
        let left = tokens(a), right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        // On the raw words, NOT on the token sets. Tokenizing drops stopwords
        // and anything under three characters, which is exactly where the
        // distinguishing word tends to live: "ship v2" and "ship v3" tokenize
        // to the same single token, as do "email Jo" and "email Al".
        if normalized(a) == normalized(b) { return true }
        guard left.intersection(right).count >= minSharedTokens else { return false }
        return jaccard(left, right) >= sameThreshold
    }

    /// High enough that it takes a near-restatement, not a shared topic: the
    /// recap paraphrasing ("Send Anna the pricing deck by Friday" for "send the
    /// deck to Anna") matches, two different tasks about the same deck do not.
    /// Measured, not guessed. On a real call the live pass and the recap
    /// described one commitment as "Create a comparison table for Blend research
    /// (comparing Telnyx and the server) and send it to Mike" and "Start the
    /// Blend vs. Telnyx/server comparison table and send it to Mike by Monday"
    /// — the same task, scoring 0.67. Every unrelated pair on that call scored
    /// 0.23 or below, so the gap is wide and this sits inside it.
    ///
    /// It can afford to be lower than it was because a match no longer decides
    /// the wording: the recap's text wins either way, and what a match moves is
    /// the evidence pointer.
    private static let sameThreshold = 0.6

    /// Case- and whitespace-insensitive, and nothing else — this is the check
    /// for the same sentence read twice, not for two sentences that mean the
    /// same thing. That is what `jaccard` below is for.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
        return Set(parts.map(String.init).filter { $0.count >= minTokenLength && !stopwords.contains($0) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
