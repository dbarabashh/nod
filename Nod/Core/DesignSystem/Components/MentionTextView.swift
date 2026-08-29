import AppKit
import SwiftUI

/// One thing that can be named in the composer, and how it is marked.
struct MentionMark: Equatable {
    /// A project has no logo, so it carries its swatch; everything else has an
    /// asset. One or the other, never both — as separate optionals the pair had
    /// four states for two real ones.
    enum Glyph: Equatable {
        case dot(NSColor)
        /// Template assets are tinted to the text colour; brand marks are drawn
        /// as they are.
        case icon(String)
    }

    let name: String
    let glyph: Glyph
    /// Where clicking it goes, in a sent message. Nil is inert.
    var url: URL?

    /// How the mention is written in the draft. The composer's pills, the
    /// scope the question carries and the sessions it pins are all answers to
    /// "is this mark named here?", and they have to be the same answer — asked
    /// four different ways, a project called "Cal" was scoped in by a sentence
    /// that only said "@Calendar".
    var token: String {
        "@\(name)"
    }

    /// Which of `items` a piece of text actually names.
    ///
    /// Longest name first, and a match claims the range it matched: "@API v2"
    /// names the project "API v2", not the project "API" that its first four
    /// letters spell. The renderer has always resolved it this way — it
    /// replaces the longest token first, so a shorter name cannot match what is
    /// already a pill — and every other answer to "is this named here?" has to
    /// agree with what the person can see, or the pills, the scope and the
    /// sessions a question reaches stop describing the same sentence.
    ///
    /// The `@` test comes first because it is the cheap one: most drafts name
    /// nothing, and this runs on every keystroke and for every visible turn.
    static func named<Item>(in text: String, from items: [Item], mark: (Item) -> MentionMark) -> [Item] {
        guard text.contains("@") else { return [] }
        let haystack = text as NSString
        var claimed: [NSRange] = []
        var found: Set<String> = []
        for item in items.sorted(by: { mark($0).name.count > mark($1).name.count }) {
            let token = mark(item).token
            var cursor = 0
            while cursor < haystack.length {
                let remaining = NSRange(location: cursor, length: haystack.length - cursor)
                let range = haystack.range(of: token, options: [.caseInsensitive], range: remaining)
                guard range.location != NSNotFound else { break }
                if !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                    claimed.append(range)
                    found.insert(token)
                    break
                }
                cursor = range.upperBound
            }
        }
        // Filtered rather than collected, so the answer keeps the caller's order
        // however the search had to walk it.
        return items.filter { found.contains(mark($0).token) }
    }

    static func named(in text: String, from marks: [MentionMark]) -> [MentionMark] {
        named(in: text, from: marks) { $0 }
    }
}

/// Draws a mention as a self-sized pill on the text baseline.
///
/// The pill used to be a rounded rect painted behind an ordinary run of text,
/// which meant its height and padding were whatever the glyph metrics happened
/// to give — it clipped against the view's edges, hugged the letters too
/// tightly, and needed a different fudge factor every time the font moved. An
/// attachment reverses that: the cell states the size it needs and the layout
/// manager makes room, so the shape is a property of the token rather than a
/// consequence of the text around it.
final class MentionCell: NSTextAttachmentCell {
    let mark: MentionMark

    private static let markSide: CGFloat = 11
    private static let gap: CGFloat = 5
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 3
    private static let fill = NSColor.themed(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.14))
    private static let border = NSColor.themed(light: .black.withAlphaComponent(0.22), dark: .white.withAlphaComponent(0.22))

    /// Everything below is fixed once the cell exists, and the layout manager
    /// asks for `cellSize()` on every pass while `draw` runs on every redraw —
    /// so the string measurement and the tinted artwork are done once here
    /// rather than tens of times a second.
    private let label: NSAttributedString
    private let labelSize: NSSize
    private let size: NSSize
    private let baselineOffset: NSPoint
    private let artwork: NSImage?

    init(mark: MentionMark) {
        self.mark = mark
        let font = MentionText.font
        label = NSAttributedString(string: mark.name, attributes: MentionText.baseAttributes())
        labelSize = label.size()
        size = NSSize(
            width: Self.horizontalPadding * 2 + Self.markSide + Self.gap + ceil(labelSize.width),
            height: ceil(font.ascender - font.descender) + Self.verticalPadding * 2
        )
        baselineOffset = NSPoint(x: 0, y: font.descender - Self.verticalPadding)
        artwork = Self.artwork(for: mark.glyph, side: Self.markSide, tint: MentionText.ink)
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MentionCell is created in code only")
    }

    override func cellSize() -> NSSize {
        size
    }

    /// The offset from the baseline to the cell's bottom edge. Without it the
    /// pill sits on the line's top and the text inside it runs high.
    override func cellBaselineOffset() -> NSPoint {
        baselineOffset
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let box = cellFrame.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        Self.fill.setFill()
        path.fill()
        Self.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let markBox = NSRect(
            x: box.minX + Self.horizontalPadding,
            y: box.midY - Self.markSide / 2,
            width: Self.markSide,
            height: Self.markSide
        )
        if case let .dot(color) = mark.glyph {
            let diameter: CGFloat = 8
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: markBox.midX - diameter / 2,
                y: markBox.midY - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()
        } else {
            artwork?.draw(in: markBox)
        }

        label.draw(at: NSPoint(x: markBox.maxX + Self.gap, y: box.midY - labelSize.height / 2))
    }

    /// Template assets are tinted in an offscreen copy. Compositing straight
    /// into the window's context punched the pill's own background out from
    /// under the mark.
    private static func artwork(for glyph: MentionMark.Glyph, side: CGFloat, tint: NSColor) -> NSImage? {
        guard case let .icon(name) = glyph, let image = NSImage(named: name) else { return nil }
        guard image.isTemplate else { return image }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

enum MentionText {
    static let font = NSFont.systemFont(ofSize: 13.5)
    /// Room for the pill, which stands a little proud of the text's ascender
    /// and descender. At a smaller inset its cap was sliced by the view's edge.
    static let verticalInset: CGFloat = 5

    /// Taken from the layout manager rather than the font's own metrics: the
    /// two disagree by a point, and a field that opens at one height and lays
    /// its first line out at another either scrolls a single row or jumps on
    /// the first keystroke.
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    /// The field's height while it holds one line.
    static let rowHeight = lineHeight + 2 * verticalInset

    static let ink = Theme.Palette.inkNS

    /// The used rect alone, which is also what `NSTextView` sizes itself to.
    ///
    /// Taking the larger of the used and bounding rects looked safer — a pill
    /// stands proud of the ascender, and the bounding rect knows it — but it
    /// made the height reported to SwiftUI disagree with the height the text
    /// view gave itself. The clip view and the document view then had different
    /// sizes, so a single line could be scrolled inside the field and sat at
    /// whatever offset it was left at. The pill's headroom comes from
    /// `verticalInset`, which the text view counts in its own sizing.
    static func contentHeight(_ layout: NSLayoutManager, in container: NSTextContainer) -> CGFloat {
        max(layout.usedRect(for: container).height, font.ascender - font.descender)
    }

    /// No paragraph style, deliberately. Line spacing was added here once so
    /// two stacked pills could not touch, but it lands *after* every line
    /// including the last — so the box grew at the bottom only and the text sat
    /// high in a field that should read as centred. The pill carries its own
    /// vertical padding, which is what keeps wrapped rows apart.
    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: ink]
    }

    /// Plain text in, tokens out. Longest names first so "Google Calendar" wins
    /// over a shorter name it contains.
    static func attributed(from plain: String, marks: [MentionMark]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: plain, attributes: baseAttributes())
        for mark in marks.sorted(by: { $0.name.count > $1.name.count }) {
            var cursor = 0
            while cursor < result.length {
                let remaining = NSRange(location: cursor, length: result.length - cursor)
                let found = (result.string as NSString).range(of: mark.token, options: [.caseInsensitive], range: remaining)
                guard found.location != NSNotFound else { break }
                let attachment = NSTextAttachment()
                attachment.attachmentCell = MentionCell(mark: mark)
                result.replaceCharacters(in: found, with: NSAttributedString(attachment: attachment))
                // The replacement is one character long, so carry on just after
                // it rather than from the old, now-stale, upper bound.
                cursor = found.location + 1
            }
        }
        return result
    }

    /// Tokens back to plain text, so the binding always holds what the person
    /// would have typed.
    static func plain(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        // The overwhelmingly common draft has no mention in it, and copying the
        // whole storage to discover that ran on every keystroke and again on
        // every SwiftUI update — which, while an answer streams, is dozens of
        // times a second.
        guard string.range(of: "\u{FFFC}").location != NSNotFound else { return attributed.string }

        var result = ""
        result.reserveCapacity(string.length)
        var cursor = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let mark = ((value as? NSTextAttachment)?.attachmentCell as? MentionCell)?.mark else { return }
            result += string.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += mark.token
            cursor = range.upperBound
        }
        result += string.substring(from: cursor)
        return result
    }

    /// One TextKit 1 stack for both surfaces, so the composer and the sent
    /// message can never disagree about metrics.
    /// - Parameter scrollable: whether the view becomes a scroll view's
    ///   document view. One that does needs the resizing contract spelled out:
    ///   without it AppKit leaves the document view at its initial frame, so it
    ///   neither follows the clip view's width nor grows with its content — and
    ///   a click lands on the clip view instead of the text, which reads as a
    ///   field that refuses the caret.
    static func makeTextView(scrollable: Bool = false) -> NSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 40), textContainer: container)
        view.isRichText = false
        view.drawsBackground = false
        view.font = font
        view.textColor = ink
        view.textContainerInset = NSSize(width: 0, height: verticalInset)
        if scrollable {
            view.minSize = NSSize(width: 0, height: 0)
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = .width
        }
        return view
    }
}

/// Lays a draft out away from the screen, so a view can be asked how tall it
/// wants to be without disturbing the one that is about to draw.
///
/// Resizing the live view to measure it fought the view that was about to draw:
/// opening the mention panel changes the composer's height, SwiftUI re-measured
/// every bubble mid-flight, and the bubble being measured was left blank while
/// its background stayed.
@MainActor
final class MentionMeasurer {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    /// Two slots, because SwiftUI asks two questions per layout pass and
    /// alternates between them — the ideal width first, then the concrete one.
    /// A single slot was evicted by every ask, so it never once answered from
    /// memory and each pass paid for two full glyph layouts.
    private var ideal: (input: MentionMeasurement, size: CGSize)?
    private var concrete: (input: MentionMeasurement, size: CGSize)?

    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }

    func size(text: String, marks: [MentionMark], width: CGFloat, isIdeal: Bool = false) -> CGSize {
        let input = MentionMeasurement(text: text, marks: marks, width: width)
        if let remembered = isIdeal ? ideal : concrete, remembered.input == input { return remembered.size }

        storage.setAttributedString(MentionText.attributed(from: text, marks: marks))
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = CGSize(
            width: min(ceil(used.width), width),
            height: ceil(MentionText.contentHeight(layout, in: container)) + 2 * MentionText.verticalInset
        )
        if isIdeal { ideal = (input, size) } else { concrete = (input, size) }
        return size
    }
}

/// What a measured size belongs to, so a repeat ask in the same layout pass is
/// a comparison rather than another full glyph layout.
private struct MentionMeasurement: Equatable {
    let text: String
    let marks: [MentionMark]
    let width: CGFloat
}

/// The composer's text area, with `@mentions` drawn as pills in place.
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var mentions: [MentionMark]
    /// Where the field stops growing and starts scrolling. The thing doing the
    /// measuring is told the cap rather than leaving the caller to clamp what
    /// it reports — split across the two, neither knew the field's real height.
    var maxHeight: CGFloat
    var isEnabled = true
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MentionText.makeTextView(scrollable: true)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.insertionPointColor = .white
        textView.typingAttributes = MentionText.baseAttributes()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        // Nothing to scroll until the text passes the five-line cap, and an
        // elastic bounce on a one-line field let the caret be dragged out of
        // sight.
        scroll.verticalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        context.coordinator.parent = self
        textView.isEditable = isEnabled

        // Rebuilt only when the model and the view genuinely disagree —
        // reassigning the storage on every keystroke would drop the caret and
        // the undo stack with it.
        //
        // The marks are half of that disagreement, not a detail of it. A tool or
        // a project is derived from the sentence, so it arrives in the same
        // update as the text that names it; a session is remembered separately
        // and lands one update later — by which time the storage already matched
        // the text, the rebuild was skipped, and the session stayed flat words
        // in a field where every other mention was a pill.
        let plain = MentionText.plain(from: storage)
        if plain != text || context.coordinator.appliedMarks != mentions {
            let caret = textView.selectedRange()
            storage.setAttributedString(MentionText.attributed(from: text, marks: mentions))
            context.coordinator.appliedMarks = mentions
            // Same sentence, new pills: the person is still typing it, so the
            // caret stays where they left it rather than jumping to the end.
            // Clamped, because a token becomes one character and everything
            // after it moves.
            let location = plain == text ? min(caret.location, storage.length) : storage.length
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.typingAttributes = MentionText.baseAttributes()
        }
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// The field's height, answered where SwiftUI asks for it.
    ///
    /// It used to be measured in the coordinator and written back through a
    /// binding, which SwiftUI drops when the write happens inside its own
    /// update pass — the composer kept whatever height its state was
    /// initialised with, so a single row could be scrolled inside a field too
    /// short for it. Answering here has no round trip to lose: the height
    /// arrives in the same layout pass as the text that caused it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // Only the height is the field's own business — it is as wide as it is
        // offered, and it says so by declining every ask that isn't a real
        // width. Answering the ideal probe with the width the text wants made
        // the row treat the composer as a fixed-width column and hand the rest
        // of the line to the send button.
        guard let width = proposal.width, width > 1, width.isFinite else { return nil }
        let measured = context.coordinator.measurer.size(text: text, marks: mentions, width: width)
        return CGSize(width: width, height: min(measured.height, maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView
        let measurer = MentionMeasurer()
        /// What the storage was last built with, so a mark that becomes known
        /// after the text does still reaches the field.
        var appliedMarks: [MentionMark] = []

        init(_ parent: MentionTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = (notification.object as? NSTextView)?.textStorage else { return }
            parent.text = MentionText.plain(from: storage)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        /// Return sends; Shift-Return breaks the line — the same contract the
        /// SwiftUI field had, restated here because `onKeyPress` never reaches
        /// an `NSTextView`.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                parent.onSend()
            }
            return true
        }
    }
}

/// A sent message, drawn with the same pills the composer showed while it was
/// being written.
struct MentionTextLabel: NSViewRepresentable {
    let text: String
    var marks: [MentionMark]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = MentionText.makeTextView()
        view.isEditable = false
        view.isSelectable = true
        view.delegate = context.coordinator
        // Filled here as well as in `updateNSView`: SwiftUI is free to measure a
        // freshly made view before it updates it, and an empty storage measures
        // to nothing.
        view.textStorage?.setAttributedString(MentionText.attributed(from: text, marks: marks))
        context.coordinator.remember(text: text, marks: marks)
        return view
    }

    /// Every bubble in the transcript is re-made on each publish of the chat
    /// store, and an answer publishes per word — so an unguarded rebuild
    /// re-allocated the attributed string and invalidated the whole TextKit
    /// layout for every visible message, tens of times a second.
    ///
    /// The guard reads what was applied rather than reconstructing the plain
    /// text out of the storage: a bubble with a pill in it holds an attachment,
    /// which is exactly the case the reconstruction's fast path cannot take, so
    /// the check walked the whole message to conclude nothing had changed. An
    /// empty storage is the one state a remembered value can be wrong about,
    /// and it is free to test.
    func updateNSView(_ view: NSTextView, context: Context) {
        guard let storage = view.textStorage else { return }
        guard storage.length == 0 || !context.coordinator.holds(text: text, marks: marks) else { return }
        context.coordinator.remember(text: text, marks: marks)
        storage.setAttributedString(MentionText.attributed(from: text, marks: marks))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        // SwiftUI asks for the ideal size first, with no width. Returning nil
        // there left it to guess, and it guessed small — the bubble laid its
        // text out three words wide and spilled past its own background. So an
        // unconstrained ask is measured on one long line and answered with the
        // width the text actually wants.
        let ceiling: CGFloat = 10_000
        let isIdeal = !(proposal.width.map { $0 > 1 && $0 < ceiling } ?? false)
        let width = isIdeal ? ceiling : (proposal.width ?? ceiling)
        return context.coordinator.measurer.size(text: text, marks: marks, width: width, isIdeal: isIdeal)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measurer = MentionMeasurer()

        private var applied: (text: String, marks: [MentionMark])?

        func holds(text: String, marks: [MentionMark]) -> Bool {
            applied?.text == text && applied?.marks == marks
        }

        func remember(text: String, marks: [MentionMark]) {
            applied = (text, marks)
        }

        /// A session mention opens its session; the others carry no url and are
        /// left alone.
        func textView(_ view: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in rect: NSRect, at index: Int) {
            guard let mention = (cell as? MentionCell)?.mark, let url = mention.url else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
