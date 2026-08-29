import SwiftUI

/// Label UI primitives shared by the meeting detail (assignment), the History
/// list (filtering), and the cross-session chat (scoping). A label always
/// reads as a coloured pill — keep that look in one place.

/// A pill naming something, with a trailing ✕ that takes it off whatever list
/// it is on. `swatch` tints the pill for a folder; without one it reads as
/// neutral chrome, which is what a plain named entry (an excluded app) wants.
struct RemovablePill: View {
    let title: String
    var swatch: Color?
    var removeHelp: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            if let swatch {
                Circle()
                    .fill(swatch)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image("nc-xmark")
                        .icon(8)
                }
                .buttonStyle(.plain)
                .help(removeHelp)
            }
        }
        .foregroundStyle(Theme.Palette.ink.opacity(swatch == nil ? 0.7 : 0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(swatch?.opacity(0.16) ?? Theme.Palette.surface)
                .overlay(Capsule().stroke(swatch?.opacity(0.4) ?? Theme.Palette.border, lineWidth: 0.5))
        )
    }
}

/// A coloured pill showing a label. Pass `onRemove` to add a trailing ✕ that
/// detaches it (used inline on the meeting detail and in the chat scope chip).
struct LabelChip: View {
    let label: SessionLabel
    var onRemove: (() -> Void)?

    var body: some View {
        RemovablePill(
            title: label.name,
            swatch: label.swatchColor,
            removeHelp: "Remove project",
            onRemove: onRemove
        )
    }
}

/// A row of tappable colour swatches for the fixed `LabelPalette`. Shared by
/// label creation and editing so the picker looks the same in both.
struct LabelSwatchRow: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LabelPalette.swatches, id: \.self) { hex in
                Circle()
                    .fill(SessionLabel.color(fromHex: hex) ?? Theme.Palette.violet)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Theme.Palette.ink, lineWidth: selection == hex ? 2 : 0))
                    .overlay(Circle().stroke(Theme.Palette.border, lineWidth: 0.5))
                    .contentShape(Circle())
                    .onTapGesture { selection = hex }
            }
        }
    }
}

/// Edit an existing label's name and colour in one place — the fix for having
/// to delete-and-recreate a label just to recolour it. Reused inline in the
/// meeting-detail picker and as a popover from the History filter bar.
struct LabelEditor: View {
    let label: SessionLabel
    var onFinish: () -> Void

    @EnvironmentObject private var labelStore: LabelStore
    @State private var name: String
    @State private var color: String

    init(label: SessionLabel, onFinish: @escaping () -> Void = {}) {
        self.label = label
        self.onFinish = onFinish
        _name = State(initialValue: label.name)
        _color = State(initialValue: label.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            LabelSwatchRow(selection: $color)
            HStack(spacing: 8) {
                Button(role: .destructive, action: delete) {
                    Image("nc-trash")
                        .icon(13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.danger)
                .help("Delete project")
                Spacer(minLength: 0)
                Button("Cancel", action: onFinish)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 12.5))
        }
        .padding(12)
    }

    private func save() {
        Task { try? await labelStore.update(label.id, name: name, color: color) }
        onFinish()
    }

    private func delete() {
        Task { try? await labelStore.delete(label.id) }
        onFinish()
    }
}

/// Assign labels to a session: toggle existing labels, create a new one inline
/// (with a colour), and edit (rename + recolour) or delete via right-click.
/// Commits through `LabelStore.setLabels` per toggle. Used from the meeting
/// detail's `＋`.
struct LabelPickerPopover: View {
    let meetingID: UUID

    @EnvironmentObject private var labelStore: LabelStore
    @State private var query = ""
    @State private var newColor = LabelPalette.default
    @State private var editing: SessionLabel?
    @State private var hovering: UUID?
    @State private var confirmingDelete: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if let editing {
                editorHeader
                Divider()
                LabelEditor(label: editing) { self.editing = nil }
            } else {
                TextField("Find or create a project", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { row($0) }
                        if canCreate { createSection }
                        if filtered.isEmpty, !canCreate {
                            Text("No projects yet")
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
        }
        .frame(width: 264)
    }

    private var editorHeader: some View {
        HStack(spacing: 6) {
            Button { editing = nil } label: {
                Image("nc-chevron-left")
                    .icon(12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.muted)
            Text("Edit project")
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(_ label: SessionLabel) -> some View {
        let confirming = confirmingDelete == label.id
        return HStack(spacing: 9) {
            Circle()
                .fill(label.swatchColor)
                .frame(width: 9, height: 9)
            Text(confirming ? "Delete project?" : label.name)
                .font(.system(size: 12.5, weight: confirming ? .medium : .regular))
                .foregroundStyle(confirming ? Theme.Palette.danger : Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if confirming {
                InlineConfirmButtons(
                    confirmIcon: "nc-trash",
                    confirmHelp: "Delete project",
                    cancelHelp: "Keep project",
                    onConfirm: { confirmDelete(label) },
                    onCancel: { confirmingDelete = nil }
                )
            } else {
                if assigned.contains(label.id) {
                    Image("nc-check")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.violet)
                }
                Button { confirmingDelete = label.id } label: {
                    Image("nc-trash")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .revealOnHover(hovering == label.id, reduceMotion: reduceMotion)
                .help("Delete project")
                .linkCursor()
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if !confirming { toggle(label) } }
        .onHover { if $0 { hovering = label.id } else if hovering == label.id { hovering = nil } }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: hovering)
        .contextMenu {
            Button("Edit project…") { editing = label }
            Button("Delete", role: .destructive) { confirmingDelete = label.id }
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LabelSwatchRow(selection: $newColor)
            Button(action: createAndAssign) {
                HStack(spacing: 6) {
                    Image("nc-grid-circle-plus")
                        .icon(13)
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
