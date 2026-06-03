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
                .fill(isUser ? Theme.Palette.violet.opacity(0.85) : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(isUser ? Color.clear : Theme.Palette.border, lineWidth: 0.5)
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
    }
}

/// The "thinking…" row shown while a reply is in flight. The label varies by
/// surface ("Thinking…" vs "Searching your sessions…").
struct ChatTypingIndicator: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.Palette.muted)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
            Spacer(minLength: 0)
        }
    }
}
