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
///
/// A bare `TextField(axis: .vertical)` with `.lineLimit(1 ... 5)` caps the
/// height but gives no scroll on macOS, so a long paste left everything below
/// the fifth line clipped and unreachable. Wrapping the field in a height-
/// bounded `ScrollView` keeps the native editing (paste, undo, IME, mentions)
/// while making the overflow scrollable.
struct ChatComposerField: View {
    let prompt: String
    @Binding var text: String
    var isEnabled: Bool = true
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    @State private var contentHeight: CGFloat = ChatComposerField.minHeight

    private static let fontSize: CGFloat = 13.5
    private static let lineHeight: CGFloat = 19 // one line at `fontSize`
    private static let maxLines: CGFloat = 5
    private static let minHeight = lineHeight
    private static let maxHeight = lineHeight * maxLines // grow to five lines, then scroll

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(Theme.Palette.ink)
                .focused(focus)
                .disabled(!isEnabled)
                .chatSubmit(text: $text, onSend: onSend)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .frame(height: min(max(contentHeight, Self.minHeight), Self.maxHeight))
        .scrollDisabled(contentHeight <= Self.maxHeight)
        .onPreferenceChange(ComposerHeightKey.self) { contentHeight = $0 }
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

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A tappable example-prompt chip shown in a chat's empty state.
struct ChatSuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
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
    private let rendered: AttributedString
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(content: String) {
        self.content = content
        rendered = renderRecapMarkdown(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rendered)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.95))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .chatBubbleBackground(isUser: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatCopyButton(text: content)
                .padding(.leading, 2)
                .revealOnHover(isHovering, reduceMotion: reduceMotion, anchor: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHovering)
    }
}

/// A user chat turn: the right-aligned violet bubble. The `.tint(.white)` keeps
/// inline links (e.g. @-mentions) legible on the violet fill.
struct UserTextBubble: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .tint(.white)
            .foregroundStyle(Color.white)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .chatBubbleBackground(isUser: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Copies an assistant reply to the pasteboard, flashing a checkmark on tap.
struct ChatCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
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
        NSPasteboard.copyText(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

/// The row shown while a reply is in flight: bouncing dots beside a label that
/// evolves as the work progresses, so the wait reads as activity rather than a
/// frozen spinner. Two ways to drive it:
///
/// - `ThinkingIndicator(phase:)` — the caller owns the label and updates it as
///   real stages complete (search → read → write). Each change cross-fades.
/// - `ThinkingIndicator(script:)` — no real sub-stages to report: the component
///   walks the given phrases on a timer and holds on the last until removed.
struct ThinkingIndicator: View {
    private let phrases: [String]
    private let interval: Double

    /// Caller-driven: `phase` reflects the current real stage; updating it
    /// animates the label. A single phrase means nothing self-cycles.
    init(phase: String) {
        phrases = [phase]
        interval = 0
    }

    /// Self-driving: cycles `script` on a timer, then holds on the last phrase.
    init(script: [String], interval: Double = 1.6) {
        phrases = script.isEmpty ? [""] : script
        self.interval = interval
    }

    @State private var displayed = ""

    var body: some View {
        HStack(spacing: 8) {
            BouncingDots()
            ZStack(alignment: .leading) {
                Text(displayed)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                    .id(displayed)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .offset(y: -6))
                    ))
            }
            .frame(height: 16, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: displayed)
            Spacer(minLength: 0)
        }
        .onAppear { if displayed.isEmpty { displayed = phrases[0] } }
        .onChange(of: phrases) { new in
            if new.count == 1 { displayed = new[0] }
        }
        .task {
            guard phrases.count > 1 else { return }
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
                    .fill(Theme.Palette.muted)
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
