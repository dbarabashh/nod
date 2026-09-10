import Foundation

/// Inline-only parser so `**bold**` renders for section headers while line
/// breaks + literal `- ` bullets the LLM emits stay intact. Block-level
/// parsing would collapse the visual structure we actually want.
///
/// Lives in `Core` because `Pasteboard` and the notch recap card render the
/// same markdown as the detail view — it was a file-level function inside a
/// feature, which put `Core` in the position of calling into `Features`.
func renderRecapMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: escapingLoneTildes(source), options: options))
        ?? AttributedString(source)
}

/// A single `~` is how a model writes "approximately" — `~600 users`,
/// `(~$4k?)` — and the parser reads a matching pair of them as strikethrough,
/// so two approximations in one line strike out everything between them. A
/// doubled `~~` is left alone: that one is the author meaning it.
func escapingLoneTildes(_ source: String) -> String {
    guard source.contains("~") else { return source }
    var escaped = ""
    escaped.reserveCapacity(source.count + 8)
    var rest = Substring(source)
    while let tilde = rest.firstIndex(of: "~") {
        escaped += rest[..<tilde]
        let afterTilde = rest.index(after: tilde)
        if afterTilde < rest.endIndex, rest[afterTilde] == "~" {
            escaped += "~~"
            rest = rest[rest.index(after: afterTilde)...]
        } else {
            escaped += "\\~"
            rest = rest[afterTilde...]
        }
    }
    return escaped + rest
}
