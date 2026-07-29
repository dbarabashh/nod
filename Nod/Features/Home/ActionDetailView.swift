import AppKit
import SwiftUI

/// One action item, opened from the attention column: what it is, when it's
/// due, and where it came from — the three questions a task pulled out of a
/// conversation has to answer before the user trusts it.
///
/// It deliberately claims nothing the transcript didn't say: the deadline is the
/// phrase that was actually spoken (anchored to the day it was said), and the
/// provenance is the session, not a guess at intent.
struct ActionDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void
    let onOpenSession: (UUID) -> Void

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The row as the store holds it — the same copy the attention column and
    /// the checklist render, so a tick here is a tick everywhere. Falls back to
    /// the one this screen was opened with, for the instant between a delete
    /// and the close.
    private var current: ActionItem {
        actionItemStore.items.first { $0.id == itemID } ?? seed
    }

    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var editorFocused: Bool

    /// Everything below depends only on the (immutable) source session, so it is
    /// resolved once. Left in `body` it re-ran on every keystroke of an inline
    /// rename: a deadline resolution, two `DateFormatter` passes and a full
    /// summary re-parse per character.
    private let itemID: UUID
    private let seed: ActionItem
    private let sessionTitle: String
    private let sessionAge: String
    private let sessionPreview: String
    private let saidOn: String

    init(
        item: ActionItem,
        meeting: Meeting,
        onClose: @escaping () -> Void,
        onOpenSession: @escaping (UUID) -> Void
    ) {
        self.meeting = meeting
        self.onClose = onClose
        self.onOpenSession = onOpenSession
        itemID = item.id
        seed = item
        sessionTitle = meeting.displayTitle(dateFormatter: Meeting.listDateFormatter)
        sessionAge = "\(meeting.kind.title) · \(Meeting.ago(meeting.startedAt))"
        sessionPreview = meeting.summaryPreview
        saidOn = Meeting.listDateFormatter.string(from: meeting.startedAt)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 22) {
                header
                title
                dueSection
                provenanceSection
                actionsRow
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .scrollContentBackground(.hidden)
        .tooltipContainer()
        .onExitCommand(perform: onClose)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .iconButtonChrome()
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
            .linkCursor()
            SectionLabel("Action")
            Spacer(minLength: 0)
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Task", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($editorFocused)
                    .chatSubmit(text: $draft) { Task { await commitEdit() } }
                    .onExitCommand { isEditing = false }
                    .onAppear { editorFocused = true }
                HStack(spacing: 8) {
                    Button("Save") { Task { await commitEdit() } }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                }
                .font(.system(size: 12.5))
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ActionCheckbox(done: current.done)
                    .onTapGesture { Task { await toggle() } }
                Text(current.text)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(current.done ? Theme.Palette.muted : Theme.Palette.ink)
                    .strikethrough(current.done, color: Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { startEdit() }
            }
        }
    }

    // MARK: - Due

    @ViewBuilder
    private var dueSection: some View {
        if let phrase = current.deadline, !phrase.isEmpty {
            let display = ActionItemDeadline.display(phrase: phrase, spokenAt: meeting.startedAt)
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("Due")
                DeadlinePill(
                    display: display,
                    spokenAt: meeting.startedAt,
                    meetingTitle: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
                    done: current.done
                )
                // The pill rewrites "end of week" into what's true today; this
                // keeps what was actually said next to it, so the rewrite is
                // never the only version the user can see.
                Text("Said as \u{201C}\(phrase)\u{201D} on \(saidOn)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Where it came from")
            Button { onOpenSession(meeting.id) } label: {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: meeting.kind.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.7))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sessionTitle)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(sessionAge)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.muted)
                        Text(sessionPreview)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.graphite)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Open the session this came from")
        }
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button { Task { await toggle() } } label: {
                Text(current.done ? "Reopen" : "Mark done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            secondaryButton("Edit", icon: "pencil", action: startEdit)
            secondaryButton("Copy", icon: "doc.on.doc") {
                NSPasteboard.copyText(current.text)
            }
            Spacer(minLength: 0)
            secondaryButton("Delete", icon: "trash", tint: Theme.Palette.danger) {
                Task { await delete() }
            }
        }
    }

    private func secondaryButton(
        _ title: String,
        icon: String,
        tint: Color = Theme.Palette.ink,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(tint.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func startEdit() {
        draft = current.text
        isEditing = true
    }

    private func commitEdit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !text.isEmpty, text != current.text else { return }
        await actionItemStore.updateText(text, itemID: itemID)
    }

    private func toggle() async {
        await actionItemStore.setDone(!current.done, itemID: itemID)
    }

    private func delete() async {
        await actionItemStore.softDelete(itemID: itemID)
        onClose()
    }
}
