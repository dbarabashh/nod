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
    return (try? AttributedString(markdown: source, options: options))
        ?? AttributedString(source)
}
