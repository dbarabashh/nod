import AppKit

extension NSPasteboard {
    /// Replace the general pasteboard's contents with a single plain-text
    /// string — the clear-then-set pair every copy button needs. Centralised so
    /// the AI-chat, response, transcript, share-link, and connector-link copy
    /// actions can't drift.
    static func copyText(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }

    /// Copy inline-Markdown as rich text. Resolves `**bold**`/`*italic*`/links
    /// into a real `NSAttributedString` and writes RTF + HTML alongside a
    /// plain-text fallback, so pasting into Word, Pages, or mail keeps the
    /// formatting instead of leaking raw `*` characters — matching what a manual
    /// select-and-copy already produces. Mirrors `renderRecapMarkdown`'s parse:
    /// inline-only, literal `- ` bullets left as text.
    static func copyRichText(markdown: String) {
        let attributed = NSAttributedString.fromInlineMarkdown(markdown)
        let range = NSRange(location: 0, length: attributed.length)
        general.clearContents()
        if let rtf = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            general.setData(rtf, forType: .rtf)
        }
        if let html = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            general.setData(html, forType: .html)
        }
        general.setString(attributed.string, forType: .string)
    }
}

private extension NSAttributedString {
    /// Inline-only Markdown → attributed string with real font traits. The raw
    /// `inlinePresentationIntent` the parser emits doesn't survive RTF/HTML
    /// serialization on its own, so bold/italic runs are given an actual bold or
    /// italic `NSFont` before bridging. Matches `renderRecapMarkdown`'s parse so
    /// the clipboard reads the same as what's on screen.
    static func fromInlineMarkdown(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source)
        }
        let baseSize: CGFloat = 13
        let base = NSFont.systemFont(ofSize: baseSize)
        let mutable = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: base, range: full)
        mutable.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            guard !traits.isEmpty,
                  let font = NSFont(
                      descriptor: base.fontDescriptor.withSymbolicTraits(traits),
                      size: baseSize
                  )
            else { return }
            mutable.addAttribute(.font, value: font, range: range)
        }
        return mutable
    }
}
