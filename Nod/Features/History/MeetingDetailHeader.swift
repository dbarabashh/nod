import SwiftUI

/// Title row of a meeting: close, the editable title, delete.
struct MeetingDetailHeader: View {
    @Binding var title: String
    let isGenerating: Bool
    /// True until the meeting row has finished its first persistence pass.
    let isFinalizing: Bool
    let isDeleting: Bool
    /// False for a session that reached this account through a folder somebody
    /// shared. Row-level security scopes the write to the owner, so the button
    /// only ever closed the pane and left the session where it was.
    var canDelete: Bool = true
    let onClose: () -> Void
    let onDelete: () -> Void
    let onTitleEdited: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            closeButton
            titleField
            if canDelete { deleteButton }
        }
    }

    /// The session is presented as a sheet over the screen it was opened from,
    /// so this closes rather than navigates back.
    private var closeButton: some View {
        Button(action: onClose) {
            Image("nc-xmark")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
                .iconButtonChrome()
        }
        .buttonStyle(.plain)
        .help("Close (esc)")
        .linkCursor()
    }

    @ViewBuilder
    private var titleField: some View {
        if isGenerating {
            Text("Generating title…")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: .placeholder)
        } else {
            TextField("Session title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: title) { _ in onTitleEdited() }
                .disabled(isFinalizing)
        }
    }

    /// Delete lives here, in the content, rather than the window toolbar — a
    /// `.primaryAction` item lands at the far right of the full-width window
    /// toolbar, which placed it over the chat dock instead of this pane.
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image("nc-trash")
                .icon(13)
                .foregroundStyle(Theme.Palette.muted)
                .iconButtonChrome()
        }
        .buttonStyle(.plain)
        .help(isFinalizing ? "Available once the meeting is saved" : "Move to Trash")
        // Soft-delete hits the server `soft_delete_meeting` RPC, which would
        // 404 for a meeting that hasn't been inserted yet. Re-enables the
        // moment the row lands.
        .disabled(isDeleting || isFinalizing)
        .opacity(isFinalizing ? 0.4 : 1)
        .linkCursor()
    }
}

/// The folders a meeting is filed under, plus the picker that changes them.
struct MeetingFoldersRow: View {
    let meetingID: UUID

    @EnvironmentObject private var labelStore: LabelStore
    @State private var showPicker = false

    var body: some View {
        let assigned = labelStore.labels(for: meetingID)
        HStack(spacing: 8) {
            Button { showPicker = true } label: {
                HStack(spacing: 4) {
                    Image("nc-tag")
                        .icon(10)
                    Text(assigned.isEmpty ? "Add to project" : "Project")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.Palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help("Add or remove projects")
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                LabelPickerPopover(meetingID: meetingID)
            }

            if !assigned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(assigned) { label in
                            LabelChip(label: label) { remove(label) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func remove(_ label: SessionLabel) {
        var set = labelStore.assignments[meetingID] ?? []
        set.remove(label.id)
        Task { try? await labelStore.setLabels(set, for: meetingID) }
    }
}

/// When the meeting happened, how long it ran, which language it was written
/// in, and — while it is still queued — that it hasn't reached the server.
struct MeetingDetailMetadata: View {
    let meeting: Meeting
    let isUnsynced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Created") {
                Text(Self.dayFormatter.string(from: meeting.startedAt)
                    + " → "
                    + Self.endTimeFormatter.string(from: meeting.endedAt))
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.92))
            }
            row("Duration") {
                HStack(spacing: 6) {
                    Image("nc-stopwatch")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.muted)
                    Text(Self.duration(from: meeting.startedAt, to: meeting.endedAt))
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                }
            }
            row("Nod language") { languageChip }
            if isUnsynced {
                row("Sync") { syncChip }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 84, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    private var languageChip: some View {
        Text(meeting.language.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(Theme.Palette.ink.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
            )
    }

    /// Shown only while the meeting is still queued in the durable outbox. The
    /// recap is safe on this device; the chip just explains why it isn't on the
    /// server yet (e.g. offline). Retry is driven by the main-window toast.
    private var syncChip: some View {
        HStack(spacing: 4) {
            Image("nc-refresh-2")
                .icon(10)
            Text("Saved on this device — syncing…")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.warning)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.warning.opacity(0.12))
                .overlay(Capsule().stroke(Theme.Palette.warning.opacity(0.35), lineWidth: 0.5))
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM, HH:mm"
        return formatter
    }()

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

/// Summary / Transcript switch, underlined on the selected tab.
struct MeetingDetailTabBar: View {
    @Binding var selection: MeetingDetailView.Tab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            button(.summary, label: "Summary")
            button(.transcript, label: "Transcript")
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 0.5)
                .offset(y: 6)
        }
        .padding(.bottom, 6)
    }

    private func button(_ tab: MeetingDetailView.Tab, label: String) -> some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) { selection = tab }
        } label: {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                    .foregroundStyle(selection == tab ? Theme.Palette.ink : Theme.Palette.muted)
                Rectangle()
                    .fill(selection == tab ? Theme.Palette.ink : Color.clear)
                    .frame(height: 1.5)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// "Vlad recorded this meeting too." Offered above the body, never acted on by
/// itself: two people in one call each keep a recording, and only a person can
/// say the two are the same meeting.
struct SameMeetingBanner: View {
    let candidates: [SameMeeting]
    /// Whether the reader can actually open the other recording. Merging into
    /// one they cannot read would hide the copy they have and show them nothing
    /// in its place, so the offer becomes a request instead.
    let canRead: (SameMeeting) -> Bool
    let isMerging: Bool
    let onMerge: (SameMeeting) -> Void
    let onDismiss: () -> Void

    private func message(for candidate: SameMeeting) -> String {
        if candidate.isMine {
            return "You recorded this room earlier — the same meeting, rejoined."
        }
        return canRead(candidate)
            ? "\(candidate.ownerName) recorded this meeting too."
            : "\(candidate.ownerName) recorded this meeting too. Ask them to share it and the two can be filed as one."
    }

    var body: some View {
        if let candidate = candidates.first {
            HStack(spacing: 10) {
                Image("nc-users")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.muted)
                Text(message(for: candidate))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Not the same", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
                if canRead(candidate) {
                    Button("File as one") { onMerge(candidate) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .disabled(isMerging)
                        .linkCursor()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
        }
    }
}
