import AppKit
import SwiftUI

/// One reference to something in a connected product — a Linear issue, and
/// later a Notion page.
struct ProviderLinkItem: Identifiable, Equatable {
    let provider: IntegrationProvider
    let title: String
    let url: URL
    /// What the model said after the reference on the same line — a status,
    /// an assignee — kept as a fact beside the title rather than lost.
    var note: String?

    var id: URL {
        url
    }

    /// One line of an answer, if that line is a reference and nothing more
    /// than a short note after it.
    ///
    /// Asked a line at a time rather than a paragraph at a time: a reference
    /// almost always follows the sentence that introduces it, inside the same
    /// paragraph, and a rule that only recognised a block of pure links left
    /// exactly those references drawn as blue markdown text.
    ///
    /// A reference inside a sentence is not this — the sentence is the point,
    /// and it is drawn whole, with the reference inline (`ReferenceText`).
    ///
    /// `- [NOD-57 — Provide team access](https://linear.app/…) — In Progress`,
    /// bullet and note optional.
    static func item(in line: String) -> ProviderLinkItem? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            rest = rest.dropFirst(bullet.count)
        }
        guard rest.hasPrefix("["),
              let split = rest.range(of: "](", options: .backwards),
              let close = rest[split.upperBound...].firstIndex(of: ")")
        else { return nil }

        let title = rest[rest.index(after: rest.startIndex) ..< split.lowerBound]
        let link = rest[split.upperBound ..< close]
        let tail = rest[rest.index(after: close)...]
        guard let url = URL(string: String(link)),
              let provider = IntegrationProvider(linkHost: url.host()),
              !title.isEmpty, !title.contains("]"),
              let note = note(from: tail)
        else { return nil }
        return ProviderLinkItem(provider: provider, title: String(title), url: url, note: note)
    }

    private static let noteLeads: Set<Character> = ["—", "–", "-", ":", "(", "["]

    /// Nil when the tail is not a note but prose the link opened — a sentence
    /// stays a sentence. `.some(nil)` when there is no tail at all.
    private static func note(from tail: Substring) -> String?? {
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let lead = trimmed.first, noteLeads.contains(lead) else { return nil }
        var note = Substring(trimmed).drop { noteLeads.contains($0) || $0 == " " }
        while let last = note.last, last == "." || last == " " || last == "—" || last == "–" {
            note = note.dropLast()
        }
        let closers: [Character: Character] = ["(": ")", "[": "]"]
        if let closer = closers[lead], note.last == closer, !note.contains(lead) {
            note = note.dropLast()
        }
        return .some(note.isEmpty ? nil : String(note))
    }
}

/// A paragraph of an answer. Plain prose is `Text`; prose with a reference in
/// it is an `NSTextView`, where the reference is the same pill the composer
/// draws for a mention — the product's mark and the title on one capsule,
/// with a pointing hand over it and a click that opens it. `Text` could draw
/// the mark and the title, but not the capsule, not the cursor, and it hangs
/// the URL off the pointer as a tooltip.
struct ReferenceProse: View {
    let block: AttributedString

    init(_ block: AttributedString) {
        self.block = block
    }

    var body: some View {
        if block.runs.contains(where: { Self.provider(of: $0) != nil }) {
            ReferenceProseLabel(block: block)
        } else {
            Text(block)
        }
    }

    static func provider(of run: AttributedString.Runs.Run) -> IntegrationProvider? {
        run.link.flatMap { IntegrationProvider(linkHost: $0.host()) }
    }

    /// The paragraph as TextKit wants it: the markdown intents resolved to
    /// fonts, and every reference replaced by a pill.
    static func attributed(from block: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in block.runs {
            let text = String(block[run.range].characters)
            if let url = run.link, let provider = IntegrationProvider(linkHost: url.host()) {
                let mark = MentionMark(name: text, glyph: .icon(provider.iconName), url: url)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = MentionCell(mark: mark)
                let pill = NSMutableAttributedString(attachment: attachment)
                pill.addAttribute(.cursor, value: NSCursor.pointingHand, range: NSRange(location: 0, length: pill.length))
                result.append(pill)
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
                attributes[.cursor] = NSCursor.pointingHand
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}

private struct ReferenceProseLabel: NSViewRepresentable {
    let block: AttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = MentionText.makeTextView(BaselineTextView.self)
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(ReferenceProse.attributed(from: block))
        context.coordinator.applied = block
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard let storage = view.textStorage else { return }
        guard storage.length == 0 || context.coordinator.applied != block else { return }
        context.coordinator.applied = block
        storage.setAttributedString(ReferenceProse.attributed(from: block))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let ceiling: CGFloat = 10_000
        let isIdeal = !(proposal.width.map { $0 > 1 && $0 < ceiling } ?? false)
        let width = isIdeal ? ceiling : (proposal.width ?? ceiling)
        let key = String(block.characters)
        let measured = context.coordinator.measurer.size(text: key, marks: [], width: width, isIdeal: isIdeal) {
            ReferenceProse.attributed(from: block)
        }
        return CGSize(width: measured.width, height: measured.height - 2 * MentionText.verticalInset)
    }

    /// Tells SwiftUI where the first line's baseline is, so a list marker in
    /// an `HStack(alignment: .firstTextBaseline)` sits on it; a plain
    /// `NSTextView` reports no baseline and the marker lands on the edge.
    final class BaselineTextView: NSTextView {
        override var firstBaselineOffsetFromTop: CGFloat {
            guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else {
                return super.firstBaselineOffsetFromTop
            }
            layoutManager.ensureLayout(for: textContainer)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return fragment.minY + layoutManager.location(forGlyphAt: 0).y + textContainerInset.height
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measurer = MentionMeasurer()
        var applied: AttributedString?

        func textView(_ view: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in rect: NSRect, at index: Int) {
            guard let url = (cell as? MentionCell)?.mark.url else { return }
            NSWorkspace.shared.open(url)
        }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

/// References rendered as rows: the product's mark stands in for the bullet, the
/// title reads as text rather than as a blue link, and the arrow is what says it
/// opens somewhere.
///
/// The only place a reference is drawn. An inline form inside `Text` existed
/// briefly and was deleted — `Text` and `HStack` are different layout systems,
/// so two renderers could be given the same colours and still never line up.
/// The model is told to put references on their own lines instead, which makes
/// one renderer enough.
struct ProviderLinkList: View {
    let items: [ProviderLinkItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                ProviderLink(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
