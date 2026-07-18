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

    /// Copy inline-Markdown as both rich text and its raw source. Resolves
    /// `**bold**`/`*italic*`/links into an `NSAttributedString` written as RTF,
    /// so pasting into Word, Pages, or mail keeps the formatting instead of
    /// leaking raw `*` characters — matching a manual select-and-copy. The
    /// plain-text fallback stays the original Markdown so plain targets (editors,
    /// Obsidian) keep link URLs and emphasis markers rather than losing them.
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
        general.setString(markdown, forType: .string)
    }
}

private extension NSAttributedString {
    /// The same inline-Markdown parse the chat shows on screen
    /// (`renderRecapMarkdown`), bridged to an attributed string with real font
    /// traits: the raw `inlinePresentationIntent` the parser emits doesn't
    /// survive RTF serialization on its own, so bold/italic runs are given an
    /// actual bold or italic `NSFont` before serializing.
    static func fromInlineMarkdown(_ source: String) -> NSAttributedString {
        let baseSize: CGFloat = 13.5
        let base = NSFont.systemFont(ofSize: baseSize)
        let mutable = NSMutableAttributedString(renderRecapMarkdown(source))
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
