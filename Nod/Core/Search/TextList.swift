import Foundation

/// Joining names the way a sentence does.
enum TextList {
    /// "Hiring", "Hiring and Pricing", "Hiring, Pricing and Roadmap".
    ///
    /// Shared because two features already write the same sentence — the chat's
    /// scope line and the notch's "with" line — and a rule about English prose
    /// spelled twice is two places to find when it becomes a rule about
    /// Ukrainian prose.
    static func prose(_ items: [String]) -> String? {
        guard let last = items.last else { return nil }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
