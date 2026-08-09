import SwiftUI

/// The "Modes" pane in Settings — where a mode is authored once: named, given a
/// recording type, a recap layout, a reply framing, and a focus describing what
/// the user is looking for. The panel's mode chip then switches all of it in one
/// tap. Edits land in `ModeStore` (local persistence); the recap layout, reply
/// framing, and focus all feed the meeting prompts via the mirrored defaults.
struct ModesSettingsSection: View {
    @ObservedObject var store: ModeStore
    @State private var editingID: UUID
    /// Drives the trailing edge-fade on the chip row: measured natural width of
    /// the chips vs the visible viewport, so the fade only appears when the row
    /// actually overflows (and never dims the last chip when everything fits).
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0

    init(store: ModeStore) {
        self.store = store
        _editingID = State(initialValue: store.selectedID)
    }

    /// Deliberately excludes glyphs the app uses functionally elsewhere — the
    /// recording types (`nc-users`/`nc-mic`/`nc-film`), transport controls, and
    /// pill icons (`nc-bullet-list`, `nc-sparkle-3`, `nc-layers-3`,
    /// `nc-stopwatch`) — so a mode's icon never reads as a recording type or a
    /// control.
    private static let iconChoices = [
        "nc-grid-2", "nc-side-profile", "nc-window-chart-line",
        "nc-msgs", "nc-tasks-2", "nc-suitcase-3", "nc-graduation-cap",
        "nc-bullhorn", "nc-lightbulb-3", "nc-flag-7", "nc-target", "nc-star", "nc-bolt-lightning", "nc-tag"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Modes apply to meetings. Each mode sets the recap layout, the reply framing, and a focus — pick one from the panel when you start a meeting instead of changing settings each time."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)

            chips

            if let mode = store.modes.first(where: { $0.id == editingID }) {
                ModeEditorForm(
                    mode: mode,
                    isActive: mode.id == store.selectedID,
                    iconChoices: Self.iconChoices,
                    canDelete: store.modes.count > 1,
                    onChange: { store.update($0) },
                    onUse: { store.select(mode.id) },
                    onDelete: {
                        store.delete(mode.id)
                        editingID = store.modes.first?.id ?? mode.id
                    }
                )
                .id(mode.id)
            }
        }
    }

    private var chipsOverflow: Bool {
        chipsContentWidth > chipsViewportWidth + 1
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.modes) { mode in
                    chip(mode)
                }
                Button {
                    editingID = store.addMode()
                } label: {
                    HStack(spacing: 5) {
                        Image("nc-plus")
                            .icon(12)
                        Text("New")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .strokeBorder(Theme.Palette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
            .readingWidth(into: $chipsContentWidth)
        }
        .readingWidth(into: $chipsViewportWidth)
        // Edge-fade the trailing side when the row overflows, so it reads as
        // horizontally scrollable rather than abruptly clipped. No fade when
        // everything fits.
        .mask(
            LinearGradient(
                stops: chipsOverflow
                    ? [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1.0)
                    ]
                    : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func chip(_ mode: MeetingMode) -> some View {
        let isEditing = mode.id == editingID
        let isActive = mode.id == store.selectedID
        return Button {
            editingID = mode.id
        } label: {
            HStack(spacing: 6) {
                Image(mode.icon)
                    .icon(11)
                Text(mode.name)
                    .font(.system(size: 12, weight: .medium))
                if isActive {
                    Circle()
                        .fill(Theme.Palette.violet)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isEditing ? Theme.Palette.ink : Theme.Palette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isEditing ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isEditing ? Color.white.opacity(0.18) : .clear, lineWidth: 0.5)
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The editor for one mode. Holds a local working copy and pushes every edit up
/// through `onChange` so the store (and the live panel chip) stay in sync.
private struct ModeEditorForm: View {
    @State private var draft: MeetingMode
    let isActive: Bool
    let iconChoices: [String]
    let canDelete: Bool
    let onChange: (MeetingMode) -> Void
    let onUse: () -> Void
    let onDelete: () -> Void

    init(
        mode: MeetingMode,
        isActive: Bool,
        iconChoices: [String],
        canDelete: Bool,
        onChange: @escaping (MeetingMode) -> Void,
        onUse: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: mode)
        self.isActive = isActive
        self.iconChoices = iconChoices
        self.canDelete = canDelete
        self.onChange = onChange
        self.onUse = onUse
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Name") {
                TextField("Mode name", text: binding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            field("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                    ForEach(iconChoices, id: \.self) { icon in
                        iconCell(icon)
                    }
                }
            }

            field("Recap layout") {
                Picker("", selection: binding(\.summary)) {
                    ForEach(SummaryTemplate.allCases) { template in
                        Text(template.displayName).tag(template)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.Palette.ink)
                .fixedSize()
                hint(draft.summary.settingsHint)
            }

            field("Focus") {
                ZStack(alignment: .topLeading) {
                    if draft.focus.isEmpty {
                        Text("What should Nod focus on in this mode? e.g. the role you're hiring for and what a strong answer looks like.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: binding(\.focus))
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Theme.Palette.border, lineWidth: 1)
                                )
                        )
                }
                hint(
                    "Added to the prompt for meeting summaries and replies, so Nod prioritizes what matters to you — it never invents facts to fit it."
                )
            }

            HStack(spacing: 12) {
                if isActive {
                    IconLabel(title: "Active mode", icon: "nc-circle-check", size: 12)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                } else {
                    Button("Use this mode", action: onUse)
                }
                Spacer(minLength: 0)
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        IconLabel(title: "Delete", icon: "nc-trash")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private func iconCell(_ icon: String) -> some View {
        let selected = draft.icon == icon
        return Button {
            draft.icon = icon
            onChange(draft)
        } label: {
            Image(icon)
                .icon(13)
                .foregroundStyle(selected ? Color.white : Theme.Palette.muted)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Theme.Palette.violet.opacity(0.8) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .tracking(0.5)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MeetingMode, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: {
                draft[keyPath: keyPath] = $0
                onChange(draft)
            }
        )
    }
}
