import AppKit
import SwiftUI

/// A whole answer as one attributed string, which is what lets `TranscriptLabel`
/// draw it in one text view and a selection run from its first line to its last.
enum AnswerText {
    static func attributed(from pieces: [AnswerPiece]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, piece) in pieces.enumerated() {
            let block = NSMutableAttributedString(attributedString: attributed(from: piece.content))
            if offset < pieces.count - 1 {
                // Two line breaks on the pasteboard, as the answer was written:
                // one reads to a markdown target as the same paragraph going on.
                endParagraph(of: block, spacing: spacing(above: offset + 1, in: pieces), copiedAs: "\n\n")
            }
            result.append(block)
        }
        return result
    }

    /// The air over a piece: a paragraph's worth, and a little more over a
    /// heading. Asked by both renderings of an answer — the one document here,
    /// and the paragraph-per-view stack it streams in as — so that finishing
    /// swaps one for the other without anything moving.
    static func spacing(above index: Int, in pieces: [AnswerPiece]) -> CGFloat {
        guard index > 0 else { return 0 }
        if case .heading = pieces[index].content { return 14 }
        return 10
    }

    private static func attributed(from content: AnswerPiece.Content) -> NSAttributedString {
        switch content {
        case let .prose(block): inline(from: block)
        case let .heading(title): heading(title)
        case let .list(items): list(items)
        case let .links(items): links(items)
        case .rule: rule()
        }
    }

    /// Closes the block's last paragraph and opens the gap under it. The gap is
    /// set on that paragraph alone: a block's own line breaks are paragraphs to
    /// TextKit too, and they sit tight.
    private static func endParagraph(of block: NSMutableAttributedString, spacing: CGFloat, copiedAs copied: String? = nil) {
        let last = (block.string as NSString).paragraphRange(for: NSRange(location: block.length - 1, length: 0))
        let current = block.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle
        let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacing += spacing
        block.addAttribute(.paragraphStyle, value: style, range: last)
        var attributes: [NSAttributedString.Key: Any] = [.font: MentionText.font, .paragraphStyle: style]
        attributes[.copyText] = copied
        block.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    /// A paragraph as TextKit wants it: the markdown intents resolved to fonts,
    /// and every reference replaced by the pill the composer draws for a
    /// mention.
    static func inline(from block: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in block.runs {
            let text = String(block[run.range].characters)
            if let url = run.link, let provider = IntegrationProvider(linkHost: url.host()) {
                let mark = MentionMark(name: text, glyph: .icon(provider.iconName), url: url)
                result.append(attachment(MentionCell(mark: mark), [.cursor: NSCursor.pointingHand, .copyText: text]))
                continue
            }
            var attributes = MentionText.baseAttributes()
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: MentionText.font.pointSize - 1, weight: .regular)
            } else if !traits.isEmpty {
                let descriptor = MentionText.font.fontDescriptor.withSymbolicTraits(traits)
                attributes[.font] = NSFont(descriptor: descriptor, size: MentionText.font.pointSize) ?? MentionText.font
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    private static func heading(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: MentionText.ink,
            .kern: 0.6,
            .copyText: title
        ])
    }

    private static func list(_ items: [AnswerPiece.ListItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, item) in items.enumerated() {
            let marker: [NSAttributedString.Key: Any] = [.font: MentionText.font, .foregroundColor: Theme.Palette.mutedNS]
            let indent = CGFloat(item.level) * 16
            let markerEdge = indent + max(10, ceil((item.marker as NSString).size(withAttributes: marker).width))
            let style = NSMutableParagraphStyle()
            style.tabStops = [
                NSTextTab(textAlignment: .right, location: markerEdge),
                NSTextTab(textAlignment: .left, location: markerEdge + 6)
            ]
            style.headIndent = markerEdge + 6

            let row = NSMutableAttributedString(string: "\t\(item.marker)\t", attributes: marker)
            row.addAttribute(
                .copyText,
                value: String(repeating: "  ", count: item.level) + item.marker + " ",
                range: NSRange(location: 0, length: row.length)
            )
            row.append(inline(from: item.text))
            row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
            if offset < items.count - 1 { endParagraph(of: row, spacing: 3) }
            result.append(row)
        }
        return result
    }

    /// References as rows: the product's mark stands in for the bullet, the
    /// title reads as text rather than as a blue link, and the arrow is what
    /// says it opens somewhere. `ProviderLink`'s `reference` style is the same
    /// row in SwiftUI, for where it stands alone; the two share their numbers.
    private static func links(_ items: [ProviderLinkItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, item) in items.enumerated() {
            let row = NSMutableAttributedString()
            let side = ProviderMark.side(for: item.provider, size: 12)
            let gap: CGFloat = 7
            let style = NSMutableParagraphStyle()
            style.headIndent = side + gap
            let mark = GlyphCell(name: item.provider.iconName, side: side, trailing: gap, drop: 1, tint: MentionText.ink)
            row.append(attachment(mark, [.copyText: ""]))
            row.append(NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: MentionText.ink
            ]))
            if let note = item.note {
                row.append(NSAttributedString(string: " ", attributes: [.font: MentionText.font, .kern: 3.5, .copyText: " — "]))
                row.append(NSAttributedString(string: note, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: Theme.Palette.mutedNS
                ]))
            }
            let arrow = GlyphCell(name: "nc-arrow-up-right", side: 9, leading: 4, drop: 0.5, tint: Theme.Palette.mutedNS)
            row.append(attachment(arrow, [.copyText: ""]))
            let whole = NSRange(location: 0, length: row.length)
            row.addAttributes([.link: item.url, .paragraphStyle: style], range: whole)
            if offset < items.count - 1 { endParagraph(of: row, spacing: 6) }
            result.append(row)
        }
        return result
    }

    private static func rule() -> NSAttributedString {
        // The line is as tall as the taller of the cell and the font, and the
        // cell is five points.
        attachment(RuleCell(), [.font: NSFont.systemFont(ofSize: 1), .copyText: "---"])
    }

    private static func attachment(_ cell: NSTextAttachmentCell, _ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// An icon on a line of text, sized and spaced like the `HStack` it replaces.
private final class GlyphCell: NSTextAttachmentCell {
    private let artwork: NSImage?
    private let side: CGFloat
    private let leading: CGFloat
    private let trailing: CGFloat
    private let drop: CGFloat

    /// - Parameter drop: how far below the baseline the glyph's bottom sits.
    init(name: String, side: CGFloat, leading: CGFloat = 0, trailing: CGFloat = 0, drop: CGFloat, tint: NSColor) {
        artwork = MentionCell.artwork(for: .icon(name), side: side, tint: tint)
        self.side = side
        self.leading = leading
        self.trailing = trailing
        self.drop = drop
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("GlyphCell is created in code only")
    }

    override func cellSize() -> NSSize {
        NSSize(width: leading + side + trailing, height: side)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -drop)
    }

    /// The row it sits in is a link; a cell that tracked the mouse would take
    /// the click and open nothing.
    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        artwork?.draw(in: NSRect(x: cellFrame.minX + leading, y: cellFrame.minY, width: side, height: side))
    }
}

/// A `---` line, drawn across whatever width the text has.
private final class RuleCell: NSTextAttachmentCell {
    private static let height: CGFloat = 5

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(x: 0, y: 0, width: max(0, lineFrag.width - position.x), height: Self.height)
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        Theme.Palette.borderNS.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.midY - 0.5, width: cellFrame.width, height: 1).fill()
    }
}

extension TranscriptLabel {
    /// A finished answer, parsed when it is first drawn and not again.
    init(answer: String, inset: CGSize = .zero) {
        self.init(key: answer, inset: inset) { AnswerText.attributed(from: AnswerPiece.pieces(in: answer)) }
    }

    /// One paragraph of an answer still arriving. A finished paragraph never
    /// changes, so where it sits says what it holds.
    init(piece: AnswerPiece) {
        self.init(key: piece.id) { AnswerText.attributed(from: [piece]) }
    }
}

#Preview {
    TranscriptLabel(
        answer: """
        A first paragraph, with **bold** in it.

        ## Next steps

        - One thing to do
          - And one under it
        1. A numbered one

        ---

        - [NOD-57 — Provide team access](https://linear.app/nod/issue/NOD-57) — In Progress
        """,
        inset: .chatBubbleInset
    )
    .chatBubbleBackground(isUser: false)
    .padding(20)
    .frame(width: 420)
    .background(Theme.Palette.bg)
}
