import SwiftUI

/// Saved "Ask Nod" conversations: the list on the left, the open thread on the
/// right. Cross-session chat used to live only in memory, so quitting the app
/// threw the answers away — these are the same conversations, kept.
struct KnowledgeThreadsView: View {
    let onOpenMeeting: (UUID) -> Void

    @EnvironmentObject private var threads: KnowledgeThreadStore
    @EnvironmentObject private var chat: KnowledgeChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The thread queued for deletion, showing an inline confirm in its row.
    @State private var confirmingDelete: UUID?

    private static let listWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider().overlay(Theme.Palette.border)
            KnowledgeChatView(onOpenMeeting: onOpenMeeting)
                .frame(maxWidth: .infinity)
        }
        .task { await threads.refreshIfNeeded() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            newChatButton
            Divider().overlay(Theme.Palette.border)
            if threads.threads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(threads.threads) { thread in
                            row(thread)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: Self.listWidth)
    }

    private var newChatButton: some View {
        Button {
            confirmingDelete = nil
            chat.startNewThread()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                Text("New chat")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ thread: KnowledgeThreadStore.Thread) -> some View {
        let isOpen = chat.threadID == thread.id
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayTitle)
                    .font(.system(size: 12.5, weight: isOpen ? .semibold : .regular))
                    .foregroundStyle(Theme.Palette.ink.opacity(isOpen ? 0.95 : 0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Meeting.shortDateFormatter.string(from: thread.updatedAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.4))
            }
            Spacer(minLength: 4)
            if confirmingDelete == thread.id {
                InlineConfirmButtons(
                    confirmIcon: "trash.fill",
                    confirmHelp: "Delete this chat",
                    cancelHelp: "Keep it",
                    onConfirm: { delete(thread) },
                    onCancel: { confirmingDelete = nil }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .opacity(isOpen ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            confirmingDelete = nil
            Task { await chat.open(threadID: thread.id) }
        }
        .contextMenu {
            Button(role: .destructive) {
                confirmingDelete = thread.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func delete(_ thread: KnowledgeThreadStore.Thread) {
        confirmingDelete = nil
        // Deleting what's on screen would leave the reader looking at a
        // conversation that no longer exists.
        if chat.threadID == thread.id {
            chat.startNewThread()
        }
        Task { await threads.delete(thread.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No saved chats yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.7))
            Text("Ask something across your sessions and it'll be kept here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
