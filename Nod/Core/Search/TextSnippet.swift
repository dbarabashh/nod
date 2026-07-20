import Foundation

/// Pulls the sentence-ish window around a match out of a longer text, so a
/// search hit can show *why* it matched instead of the opening line of a recap
/// that may have nothing to do with the query.
enum TextSnippet {
    /// Characters of context kept on each side of the match.
    private static let padding = 70

    static func around(_ needle: String, in haystack: String, limit: Int = 180) -> String? {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        let flat = haystack
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !flat.isEmpty,
              let match = flat.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }

        let start = flat.index(match.lowerBound, offsetBy: -padding, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(match.upperBound, offsetBy: padding, limitedBy: flat.endIndex) ?? flat.endIndex
        // Snap to whitespace so the snippet doesn't start or end mid-word.
        let snapped = flat[wordStart(in: flat, from: start) ..< wordEnd(in: flat, from: end)]
        var text = String(snapped).trimmingCharacters(in: .whitespaces)
        if text.count > limit {
            text = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        if start > flat.startIndex { text = "…" + text }
        if end < flat.endIndex, !text.hasSuffix("…") { text += "…" }
        return text
    }

    private static func wordStart(in text: String, from index: String.Index) -> String.Index {
        guard index > text.startIndex else { return index }
        guard let space = text[index...].firstIndex(of: " ") else { return index }
        return text.index(after: space)
    }

    private static func wordEnd(in text: String, from index: String.Index) -> String.Index {
        guard index < text.endIndex else { return index }
        return text[..<index].lastIndex(of: " ") ?? index
    }
}
