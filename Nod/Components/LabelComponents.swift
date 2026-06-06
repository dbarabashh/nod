import SwiftUI

/// Label UI primitives shared by the meeting detail (assignment), the History
/// list (filtering), and the cross-session chat (scoping). A label always
/// reads as a coloured pill — keep that look in one place.

/// A coloured pill showing a label. Pass `onRemove` to add a trailing ✕ that
/// detaches it (used inline on the meeting detail and in the chat scope chip).
struct LabelChip: View {
    let label: SessionLabel
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(label.swatchColor)
                .frame(width: 7, height: 7)
            Text(label.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove label")
            }
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(label.swatchColor.opacity(0.16))
                .overlay(Capsule().stroke(label.swatchColor.opacity(0.4), lineWidth: 0.5))
        )
    }
}

/// A selectable label pill for the History filter strip and the chat scope
/// picker. Filled with the label's colour when selected.
struct LabelFilterChip: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Theme.Palette.ink.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? color.opacity(0.85) : Theme.Palette.surface)
                    .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.Palette.border, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Assign labels to a session: toggle existing labels, create a new one inline
/// (with a colour), and rename/delete via right-click. Commits through
/// `LabelStore.setLabels` per toggle. Used from the meeting detail's `＋`.
struct LabelPickerPopover: View {
    let meetingID: UUID

    @EnvironmentObject private var labelStore: LabelStore
    @State private var query = ""
    @State private var newColor = LabelPalette.default
    @State private var renaming: SessionLabel?
    @State private var renameText = ""
    @State private var hovering: UUID?
    @State private var confirmingDelete: UUID?

    private var assigned: Set<UUID> {
        labelStore.assignments[meetingID] ?? []
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [SessionLabel] {
        guard !trimmedQuery.isEmpty else { return labelStore.labels }
        return labelStore.labels.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var canCreate: Bool {
        !trimmedQuery.isEmpty &&
            !labelStore.labels.contains { $0.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find or create a label", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { row($0) }
                    if canCreate { createSection }
                    if filtered.isEmpty, !canCreate {
                        Text("No labels yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 264)
        .alert("Rename label", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let label = renaming { Task { try? await labelStore.rename(label.id, to: renameText) } }
                renaming = nil
            }
        }
    }

    private func row(_ label: SessionLabel) -> some View {
        let confirming = confirmingDelete == label.id
        return HStack(spacing: 9) {
            Circle()
                .fill(label.swatchColor)
                .frame(width: 9, height: 9)
            Text(confirming ? "Delete label?" : label.name)
                .font(.system(size: 12.5, weight: confirming ? .medium : .regular))
                .foregroundStyle(confirming ? Theme.Palette.danger : Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if confirming {
                InlineConfirmButtons(
                    confirmIcon: "trash.fill",
                    confirmHelp: "Delete label",
                    cancelHelp: "Keep label",
                    onConfirm: { confirmDelete(label) },
                    onCancel: { confirmingDelete = nil }
                )
            } else {
                if assigned.contains(label.id) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.violet)
                }
                Button { confirmingDelete = label.id } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .opacity(hovering == label.id ? 1 : 0)
                .help("Delete label")
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if !confirming { toggle(label) } }
        .onHover { if $0 { hovering = label.id } else if hovering == label.id { hovering = nil } }
        .contextMenu {
            Button("Rename") { renaming = label; renameText = label.name }
            Button("Delete", role: .destructive) { confirmingDelete = label.id }
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                ForEach(LabelPalette.swatches, id: \.self) { hex in
                    Circle()
                        .fill(SessionLabel.color(fromHex: hex) ?? Theme.Palette.violet)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white, lineWidth: newColor == hex ? 2 : 0))
                        .onTapGesture { newColor = hex }
                }
            }
            Button(action: createAndAssign) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SessionLabel.color(fromHex: newColor) ?? Theme.Palette.violet)
                    Text("Create “\(trimmedQuery)”")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
    }

    private func confirmDelete(_ label: SessionLabel) {
        confirmingDelete = nil
        Task { try? await labelStore.delete(label.id) }
    }

    private func toggle(_ label: SessionLabel) {
        var set = assigned
        if set.contains(label.id) { set.remove(label.id) } else { set.insert(label.id) }
        Task { try? await labelStore.setLabels(set, for: meetingID) }
    }

    private func createAndAssign() {
        let name = trimmedQuery
        let color = newColor
        Task {
            guard let created = try? await labelStore.create(name: name, color: color) else { return }
            var set = assigned
            set.insert(created.id)
            try? await labelStore.setLabels(set, for: meetingID)
        }
        query = ""
        newColor = LabelPalette.default
    }
}
