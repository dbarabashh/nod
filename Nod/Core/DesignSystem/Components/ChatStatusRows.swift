import SwiftUI

/// What a chat turn says when it didn't simply answer: it failed, it was
/// stopped, or it never reached the server. Shared by the per-session chat
/// (`SessionChatView`) and the cross-session "Ask Nod" chat
/// (`KnowledgeChatView`) — the two threads fail in the same ways, and two
/// copies of these rows are two chances to say it differently.

/// Why a turn produced no answer, and the one thing worth doing about it.
///
/// A row in the thread rather than a modal or a toast: the failure belongs to
/// the question above it, and a dialog over the conversation blocks the thread
/// it is describing. Anything the turn managed to do before it broke stays
/// above the row — a tool call that ran is the difference between "nothing
/// happened" and "the ticket exists, the summary doesn't". The technical text
/// is kept behind a disclosure: dropping it makes every report of a broken
/// chat unactionable, and showing it makes every failure unreadable.
struct ChatErrorRow: View {
    let failure: ChatFailure
    /// Only the retry. Upgrading is an app-global navigation that is the same
    /// act on every surface, so it is handled here rather than reimplemented
    /// identically by each chat.
    let onRetry: () -> Void

    @State private var showsDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatTurnTrace(steps: failure.steps)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image("nc-triangle-warning")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.warning)
                    Text(failure.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let label = failure.recovery.label {
                        Button(label) { recover() }
                            .controlSize(.small)
                    }
                }
                if let detail = failure.detail {
                    disclosure(detail)
                }
            }
            .animation(.standard(reduceMotion: reduceMotion), value: showsDetail)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                    .fill(Theme.Palette.warning.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                            .stroke(Theme.Palette.warning.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
    }

    private func recover() {
        switch failure.recovery {
        case .retry:
            onRetry()
        case .upgrade:
            NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
        case .none:
            break
        }
    }

    @ViewBuilder
    private func disclosure(_ detail: String) -> some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 5) {
                Image("nc-chevron-down")
                    .icon(9)
                    .rotationEffect(.degrees(showsDetail ? 0 : -90))
                Text("Details")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
        if showsDetail {
            Text(detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Palette.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// What a finished turn has to admit: it was stopped part-way, or it never
/// reached the server. Both chats say it the same way — the words and the icon
/// are the promise, and two copies of them are two chances to break it.
struct ChatTurnNotes: View {
    var wasStopped = false
    var isUnsaved = false
    /// Where the turn lives when it saves, in the words of the surface showing
    /// it — "this thread" for Ask Nod, "this session" for a session chat.
    var storeNoun: String
    var onRetrySave: () -> Void

    var body: some View {
        if wasStopped {
            ChatNoteRow(icon: "nc-hand", text: "You stopped this answer.")
        }
        if isUnsaved {
            ChatNoteRow(
                icon: "nc-circle-xmark",
                text: "Not saved to \(storeNoun).",
                action: ("Retry", onRetrySave)
            )
        }
    }
}

/// A quiet one-line note under a turn: it was stopped, or it isn't saved.
///
/// Deliberately not `ChatErrorRow`. Neither is a failure — one is what the
/// person asked for, the other is a fact about durability — and dressing them
/// in a warning box teaches people to ignore the box that matters.
struct ChatNoteRow: View {
    let icon: String
    let text: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(icon)
                .icon(10)
            Text(text)
                .font(.system(size: 11))
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.violet)
                    .linkCursor()
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.muted)
    }
}
