import AppKit
import SwiftUI

/// Chat UI primitives shared by the per-session chat (`SessionChatView`) and
/// the cross-session "Ask Nod" chat (`KnowledgeChatView`). The two threads
/// differ in their data model and grounding, but render the same bubbles,
/// suggestion chips, and typing affordance — keep that look in one place.

extension View {
    /// The standard chat-bubble background: violet for the user's turn, the
    /// surface colour with a hairline border for the assistant's.
    func chatBubbleBackground(isUser: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isUser ? Color.white.opacity(0.14) : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(isUser ? Color.clear : Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    /// Messaging-convention submit for a multiline composer: plain Return
    /// sends, Shift+Return inserts a newline. Both Return events are consumed —
    /// letting Shift+Return fall through made AppKit treat Shift as a selection
    /// modifier and select-all instead of inserting a line break — so we insert
    /// the newline ourselves, at the caret in the focused field editor (a plain
    /// append landed at the end of the text, which is wrong once the field
    /// scrolls and the caret can sit mid-text). On macOS 13, where `onKeyPress`
    /// is unavailable, falls back to `onSubmit` (Return sends; the field inserts
    /// the newline natively on Shift+Return).
    @ViewBuilder
    func chatSubmit(text: Binding<String>, onSend: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onKeyPress(phases: .down) { keyPress in
                guard keyPress.key == .return else { return .ignored }
                if keyPress.modifiers.contains(.shift) {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.insertText("\n", replacementRange: editor.selectedRange())
                    } else {
                        text.wrappedValue += "\n"
                    }
                } else {
                    onSend()
                }
                return .handled
            }
        } else {
            onSubmit(onSend)
        }
    }
}

/// The chat composer input shared by both threads. Grows with its content up
/// to roughly five lines, then scrolls internally instead of clipping.
struct ChatComposerField: View {
    let prompt: String
    @Binding var text: String
    var isEnabled: Bool = true
    @Binding var isFocused: Bool
    /// Names to draw as pills. Empty is the ordinary case — a question with no
    /// mention in it looks exactly as it did.
    var mentions: [MentionMark] = []
    let onSend: () -> Void

    private static let maxLines: CGFloat = 5
    private static let maxHeight = MentionText.rowHeight + (maxLines - 1) * MentionText.lineHeight

    var body: some View {
        MentionTextView(
            text: $text,
            isFocused: $isFocused,
            mentions: mentions,
            maxHeight: Self.maxHeight,
            isEnabled: isEnabled,
            onSend: onSend
        )
        // `NSTextView` has no placeholder, and the one it does expose is not
        // public API — so the prompt is drawn behind it and hidden on the first
        // character. Centred rather than offset by the text view's inset: the
        // field is exactly one row tall whenever the prompt is showing, so the
        // centre is where the caret is, and it stays there whatever the two
        // font stacks make of the same point size.
        .overlay(alignment: .leading) {
            if text.isEmpty {
                Text(prompt)
                    .font(.system(size: MentionText.font.pointSize))
                    .foregroundStyle(Theme.Palette.muted)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }
}

/// A tappable example-prompt chip shown in a chat's empty state.
struct ChatSuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image("nc-sparkle-3")
                    .icon(10)
                Text(text)
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

/// An assistant chat turn: the rendered reply with a copy affordance that
/// reveals on hover. Shared by the per-session and cross-session chats so the
/// bubble, markdown rendering, and copy behaviour stay identical. Callers
/// supply the trailing layout (gutter spacer, any sources row).
struct AssistantTextBubble: View {
    private let content: String
    private let rendered: [AnswerPiece]
    private let showsBubble: Bool
    private let isStreaming: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set on the newest answer only. Regenerating an older one would orphan
    /// every turn after it, which was written against the answer being
    /// replaced — so the affordance simply isn't offered there.
    private let onRegenerate: (() -> Void)?

    /// `showsBubble: false` is the same answer without the chat chrome — used
    /// where the surface itself is already the container (the launcher panel),
    /// so the markdown rendering and the copy affordance stay shared instead of
    /// being written a second time.
    init(content: String, showsBubble: Bool = true, isStreaming: Bool = false, onRegenerate: (() -> Void)? = nil) {
        self.content = content
        self.showsBubble = showsBubble
        self.isStreaming = isStreaming
        self.onRegenerate = onRegenerate
        // Rendered once here, not in `body`: re-parsing the whole markdown on
        // every body pass is quadratic in the answer's length. While streaming,
        // `StreamingAnswer` parses per block instead — also once each.
        rendered = isStreaming
            ? []
            : AnswerBlocks.complete(in: content, isFinished: true)
            .enumerated()
            .flatMap { AnswerPiece.pieces(from: $0.element, at: $0.offset) }
    }

    /// Nothing to show yet: the turn exists but no paragraph has finished. The
    /// thinking indicator is carrying the wait, and an empty bubble beside it
    /// would read as a stalled answer.
    private var isAwaitingFirstBlock: Bool {
        isStreaming && !AnswerBlocks.hasComplete(in: content)
    }

    var body: some View {
        if isAwaitingFirstBlock {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if isStreaming {
                        StreamingAnswer(content: content)
                    } else {
                        AnswerPieces(pieces: rendered)
                    }
                }
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.95))
                .textSelection(.enabled)
                .padding(.horizontal, showsBubble ? 12 : 0)
                .padding(.vertical, showsBubble ? 9 : 0)
                .modifier(ChatBubbleFill(isEnabled: showsBubble))
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isStreaming {
                    // One row of actions on hover rather than a button that
                    // only appears once something has gone wrong: asking for
                    // the answer again is an ordinary thing to want, and a
                    // pointer is already here to reveal it.
                    HStack(spacing: 10) {
                        ChatCopyButton(text: content)
                        if let onRegenerate {
                            ChatActionButton(icon: "nc-refresh-2", label: "Regenerate", action: onRegenerate)
                        }
                    }
                    .padding(.leading, 2)
                    .revealOnHover(isHovering, reduceMotion: reduceMotion, anchor: .leading)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHovering)
        }
    }
}

/// The answer as it is written, one finished paragraph at a time.
///
/// Two failure modes bracket this. Revealing character by character types the
/// answer *at* the reader — a sentence assembling itself is slower to read than
/// a finished one, and the motion never stops. Withholding everything until the
/// end leaves fifteen seconds of nothing, which reads as a stall no matter what
/// the indicator says.
///
/// So the unit of reveal is the paragraph: nothing appears half-written, the
/// first one lands within a second or two of the model starting, and each
/// arrives whole and stays still. What is on screen is always readable, and
/// what is still being written is never on screen.
private struct StreamingAnswer: View {
    let content: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Parsed once each, in arrival order. A finished paragraph never changes,
    /// so re-parsing the ones already on screen — twenty times a second, for the
    /// length of the answer — is the quadratic cost the non-streaming path
    /// avoids by parsing in `init`.
    @State private var rendered: [AnswerPiece] = []
    /// How many blocks those pieces came from. Counting pieces stopped
    /// answering that the moment one block could produce several.
    @State private var absorbed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rendered) { piece in
                AnswerPieceView(piece: piece)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.answerArrival(reduceMotion: reduceMotion))
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: rendered.count)
        .onAppear { absorb(content) }
        .onChange(of: content) { absorb($0) }
    }

    /// Parses only what is newly complete. Blocks are append-only while an
    /// answer streams, so everything already rendered is left alone.
    private func absorb(_ text: String) {
        let blocks = AnswerBlocks.complete(in: text, isFinished: false)
        guard blocks.count > absorbed else { return }
        let first = absorbed
        absorbed = blocks.count
        rendered += blocks[first...].enumerated().flatMap { AnswerPiece.pieces(from: $0.element, at: first + $0.offset) }
    }
}

/// One rendered piece of an answer.
struct AnswerPiece: Identifiable {
    enum Content {
        case prose(AttributedString)
        case links([ProviderLinkItem])
    }

    /// Position, not text: blocks are append-only while an answer streams, so
    /// where a piece sits is its identity — and reading it must not cost a copy
    /// of the paragraph, in a list SwiftUI re-diffs at every stream flush. A
    /// block can now yield more than one piece, so the run within it is the
    /// second half of the address.
    let id: String
    let content: Content

    /// Splits a paragraph into what it actually holds: runs of reference lines,
    /// drawn as rows, and everything else, drawn as markdown.
    ///
    /// This used to ask whether the *whole* block was references, and a block
    /// that mixed a sentence with the ticket it named — which is how the model
    /// writes almost every one of them — fell through to markdown. The
    /// reference then rendered as blue `Text`, with no mark, no pointer cursor
    /// and nothing to click.
    static func pieces(from block: String, at index: Int) -> [AnswerPiece] {
        var pieces: [AnswerPiece] = []
        var prose: [String] = []
        var links: [ProviderLinkItem] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            let text = prose.joined(separator: "\n")
            prose = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pieces.append(AnswerPiece(id: "\(index).\(pieces.count)", content: .prose(renderRecapMarkdown(text))))
        }

        func flushLinks() {
            guard !links.isEmpty else { return }
            let items = links
            links = []
            pieces.append(AnswerPiece(id: "\(index).\(pieces.count)", content: .links(items)))
        }

        for line in block.components(separatedBy: .newlines) {
            if let item = ProviderLinkItem.item(in: line) {
                flushProse()
                links.append(item)
            } else {
                flushLinks()
                prose.append(line)
            }
        }
        flushProse()
        flushLinks()
        return pieces
    }
}

/// Draws a sequence of answer pieces with the paragraph spacing of a reply.
struct AnswerPieces: View {
    let pieces: [AnswerPiece]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pieces) { AnswerPieceView(piece: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AnswerPieceView: View {
    let piece: AnswerPiece

    var body: some View {
        switch piece.content {
        case let .prose(block):
            Text(block)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .links(items):
            ProviderLinkList(items: items)
        }
    }
}

/// Splits an answer into the paragraphs that are safe to show.
enum AnswerBlocks {
    /// Blocks separated by a blank line, minus the one still being written.
    ///
    /// A blank line is the one boundary that survives partial markdown: a list
    /// stays whole (its items are single newlines), a heading stays attached to
    /// the lines under it, and no `**bold` is ever shown with its closing
    /// asterisks missing. While the answer is unfinished the trailing block is
    /// held back — it is, by definition, the one mid-sentence.
    /// Whether anything is showable yet, without paying for the split. Asked on
    /// every body pass of a view that re-renders per stream flush, where the
    /// only question is "is there a first paragraph".
    /// Whether `complete(in:isFinished:)` would hand the renderer anything yet.
    ///
    /// Defined in terms of that call rather than re-deriving the rule: as
    /// `text.contains("\n\n")` this was true the instant the model emitted the
    /// blank line, while the renderer holds a paragraph back until a *second*
    /// one has started. The two disagreed for exactly as long as the next token
    /// took to arrive, and the bubble drew its chrome around nothing.
    static func hasComplete(in text: String) -> Bool {
        !complete(in: text, isFinished: false).isEmpty
    }

    static func complete(in text: String, isFinished: Bool) -> [String] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !isFinished else { return blocks }
        guard blocks.count <= 1 else { return Array(blocks.dropLast()) }
        // A single paragraph has no successor to prove it finished, so holding
        // it back means holding back the *whole* answer — and a short answer,
        // which is most of what the launcher gets, showed nothing at all until
        // the stream ended. A sentence that has reached its full stop is not
        // half-written, so it can be read while the rest is still coming.
        return blocks.first.flatMap(finishedSentences).map { [$0] } ?? []
    }

    /// The part of a paragraph up to its last sentence ending, or nil while it
    /// has not reached one. Never returns a clause mid-flight: the point is to
    /// show sooner, not to show something unfinished.
    static func finishedSentences(in block: String) -> String? {
        guard let end = block.lastIndex(where: { sentenceEndings.contains($0) }) else { return nil }
        let sentence = block[...end].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    private static let sentenceEndings: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
}

/// Applies the assistant bubble only when the surface isn't already one.
private struct ChatBubbleFill: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.chatBubbleBackground(isUser: false)
        } else {
            content
        }
    }
}

/// A user chat turn: the right-aligned bubble. A turn that named something is
/// drawn by `MentionTextLabel`, so its pills match the ones the composer showed
/// while the question was being written.
struct UserTextBubble: View {
    let text: String
    /// Present when the turn named something. Empty keeps the plain `Text`
    /// path, which is most messages in both chats.
    var marks: [MentionMark] = []

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if marks.isEmpty {
                    Text(text)
                        .font(.system(size: MentionText.font.pointSize))
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                } else {
                    MentionTextLabel(text: text, marks: marks)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .chatBubbleBackground(isUser: true)
            // Copying your own turn is how a question gets reused — reworded in
            // a new thread, or pasted somewhere else. The affordance mirrors the
            // assistant's, flipped to the side this bubble sits on.
            ChatCopyButton(text: text)
                .padding(.trailing, 2)
                .revealOnHover(isHovering, reduceMotion: reduceMotion, anchor: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHovering)
    }
}

/// Copies an assistant reply to the pasteboard, flashing a checkmark on tap.
struct ChatCopyButton: View {
    let text: String
    @State private var copied = false
    @State private var flash: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(copied ? "nc-check" : "nc-files-2")
                    .icon(10)
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(copied ? Theme.Palette.violet : Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
        .linkCursor()
    }

    private func copy() {
        NSPasteboard.copyRichText(markdown: text)
        flash?.cancel()
        flash = Task {
            await flashConfirmation(set: { copied = true }, reset: { copied = false }, for: 1.5)
        }
    }
}

/// A small labelled action in a chat turn's hover row. Shares the copy
/// button's weight and colour so the row reads as one strip rather than as a
/// button that arrived from somewhere else.
struct ChatActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(icon)
                    .icon(10)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .help(label)
        .linkCursor()
    }
}

/// The row shown while a reply is in flight: bouncing dots beside a label that
/// evolves as the work progresses, so the wait reads as activity rather than a
/// frozen spinner.
///
/// The caller says what the current stage may show; the component paces it,
/// cross-fading between lines and holding on the last. Handing over a new
/// script — the next real stage — restarts the walk, so a caller that knows a
/// stage's facts (how many sessions matched) and one that doesn't drive the
/// same view the same way.
struct ThinkingIndicator: View {
    private let phrases: [String]
    private let interval: Double
    private let icon: String?

    /// `icon` marks work that left Nod: while the chat is calling a connected
    /// product, its mark stands next to the dots so the wait is attributable
    /// rather than anonymous.
    init(script: [String], icon: String? = nil, interval: Double = 1.6) {
        phrases = script.isEmpty ? [""] : script
        self.icon = icon
        self.interval = interval
    }

    @State private var displayed = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(icon)
                    .icon(13)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            BouncingDots()
            ZStack(alignment: .leading) {
                Text(displayed)
                    // Vibrancy, not flat grey: over a translucent surface a
                    // muted tone dissolves into whatever is behind the window.
                    // Brighter tint, a little more weight, a touch of tracking.
                    .font(.system(size: 12, weight: .medium))
                    .tracking(0.1)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.78))
                    .id(displayed)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .offset(y: -6))
                    ))
            }
            .frame(height: 16, alignment: .leading)
            .animation(.standard(reduceMotion: reduceMotion), value: displayed)
            Spacer(minLength: 0)
        }
        .animation(.standard(reduceMotion: reduceMotion), value: icon)
        // Keyed on the script, so handing over a new stage's phrases restarts
        // the walk instead of leaving the previous stage's timer running.
        .task(id: phrases) {
            displayed = phrases[0]
            for phrase in phrases.dropFirst() {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                displayed = phrase
            }
        }
    }
}

/// Three dots that bounce in a staggered wave — the activity glyph for
/// `ThinkingIndicator`.
private struct BouncingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.Palette.ink.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .opacity(animating ? 1 : 0.35)
                    .offset(y: animating ? -2 : 1)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
