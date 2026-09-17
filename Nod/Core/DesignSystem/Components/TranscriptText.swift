import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// What a range is copied as, where that differs from what it draws: a
    /// heading is shown in capitals it was not written in, a list marker sits
    /// between two tabs, and a pill or a glyph is an attachment character.
    /// Declared where the stand-in is built, so copying has no list of them.
    static let copyText = NSAttributedString.Key("app.hellonod.copyText")
}

extension NSAttributedString {
    /// A range as it should land on the pasteboard: every stand-in put back to
    /// the words it stands for, and none of the screen's colours — white ink
    /// pasted into a white document is an empty paste.
    func copyable(in range: NSRange) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = string as NSString
        enumerateAttributes(in: range) { attributes, run, _ in
            var kept: [NSAttributedString.Key: Any] = [:]
            for key in [NSAttributedString.Key.font, .link, .strikethroughStyle] {
                kept[key] = attributes[key]
            }
            // Read off the pill rather than set on it: a `.link` on the
            // attachment would change what a click on it does on screen.
            if let mark = ((attributes[.attachment] as? NSTextAttachment)?.attachmentCell as? MentionCell)?.mark {
                kept[.link] = mark.url
            }
            let copied = (attributes[.copyText] as? String).map { portion(of: $0, for: run) } ?? source.substring(with: run)
            result.append(NSAttributedString(string: copied, attributes: kept))
        }
        return result
    }

    /// Half a heading selected is half a heading copied. That only has an
    /// answer where the replacement lines up with what is drawn character for
    /// character; anything else — a marker, a glyph — is copied whole.
    private func portion(of replacement: String, for run: NSRange) -> String {
        var whole = NSRange()
        _ = attribute(.copyText, at: run.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: length))
        let source = replacement as NSString
        guard source.length == whole.length else { return replacement }
        return source.substring(with: NSRange(location: run.location - whole.location, length: run.length))
    }
}

/// The text view behind every turn of a transcript: read-only, selectable end
/// to end, and copying what the person read rather than what TextKit holds.
final class TranscriptTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        selectedRange().length > 0 ? [.rtf, .string] : []
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let textStorage, type == .rtf || type == .string else {
            return super.writeSelection(to: pboard, type: type)
        }
        let copied = NSMutableAttributedString()
        for range in selectedRanges.map(\.rangeValue) where range.length > 0 {
            copied.append(textStorage.copyable(in: range))
        }
        guard type == .rtf else { return pboard.setString(copied.string, forType: .string) }
        // The plain string is written beside it, so a failed RTF is a copy
        // without its bold rather than a failed copy.
        guard let rtf = try? copied.data(
            from: NSRange(location: 0, length: copied.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else { return false }
        return pboard.setData(rtf, forType: .rtf)
    }

    /// A transcript is many of these, and each would otherwise keep its own
    /// highlight after the person moved on to select in another.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        return super.resignFirstResponder()
    }
}

/// One turn of a transcript — an answer, a paragraph of one still arriving, or
/// a sent message — as a single selectable surface.
///
/// One `NSTextView` because that is the only thing a selection can cross. Drawn
/// as a stack of SwiftUI views — a `Text` per paragraph — each paragraph was its
/// own selection: a drag stopped at the paragraph's edge, and one that began in
/// the gap between two began nowhere.
struct TranscriptLabel: NSViewRepresentable {
    /// What `build` renders. Compared instead of built: every bubble in the
    /// transcript is re-made on each publish of the chat store, and an answer
    /// publishes per word — so `build` runs when these change and at no other
    /// time, however often the view is re-made.
    let key: String
    /// A mark can become known an update after the text that names it.
    var marks: [MentionMark] = []
    /// The bubble's padding, given to the text view rather than put around it,
    /// so a drag that starts in the margin still starts a selection.
    var inset: CGSize = .zero
    /// A sent message is as wide as its words. An answer's bubble is drawn full
    /// width whatever it holds, and one hugging a short answer left most of
    /// that bubble a place where a drag selected nothing.
    var hugsContent = false
    let build: () -> NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = MentionText.makeTextView(TranscriptTextView.self)
        view.isEditable = false
        view.isSelectable = true
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        // A reference row is a link from edge to edge, and the URL hanging off
        // the pointer over every one of them is noise the old rows never made.
        view.displaysLinkToolTips = false
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TranscriptTextView, context: Context) {
        if view.textContainerInset != inset { view.textContainerInset = inset }
        guard let storage = view.textStorage else { return }
        // An empty storage is the one state a remembered key can be wrong
        // about, and it is free to test.
        guard storage.length == 0 || !context.coordinator.holds(key, marks) else { return }
        storage.setAttributedString(context.coordinator.attributed(for: key, marks, build: build))
        context.coordinator.applied = (key, marks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTextView, context: Context) -> CGSize? {
        // SwiftUI asks for the ideal size first, with no width. Returning nil
        // there left it to guess, and it guessed small — the bubble laid its
        // text out three words wide and spilled past its own background. So an
        // unconstrained ask is measured on one long line and answered with the
        // width the text actually wants.
        let ceiling: CGFloat = 10_000
        let offered = proposal.width.flatMap { $0 > 1 && $0 < ceiling ? $0 : nil }
        let used = context.coordinator.measurer.usedSize(
            text: key,
            marks: marks,
            width: offered.map { max(1, $0 - 2 * inset.width) } ?? ceiling,
            isIdeal: offered == nil
        ) {
            context.coordinator.attributed(for: key, marks, build: build)
        }
        let hugging = used.width + 2 * inset.width
        return CGSize(width: hugsContent ? hugging : offered ?? hugging, height: used.height + 2 * inset.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measurer = MentionMeasurer()
        var applied: (key: String, marks: [MentionMark])?

        private var built: (key: String, marks: [MentionMark], text: NSAttributedString)?

        func holds(_ key: String, _ marks: [MentionMark]) -> Bool {
            applied?.key == key && applied?.marks == marks
        }

        /// Built once per turn. The view, the ideal measure and the concrete
        /// one all want it, and a build is a markdown parse and a cell per pill.
        func attributed(for key: String, _ marks: [MentionMark], build: () -> NSAttributedString) -> NSAttributedString {
            if let built, built.key == key, built.marks == marks { return built.text }
            let text = build()
            built = (key, marks, text)
            return text
        }

        /// A reference opens what it names, and a session mention its session;
        /// a mark that carries no url is left alone.
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
