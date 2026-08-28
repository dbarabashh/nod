import SwiftUI

/// Writing a beat: a sentence and a time. No conditions, no steps, no target —
/// whatever a person can type into Ask Nod, they can put on a schedule, and the
/// editor's job is to stay out of the way of that sentence.
///
/// Every control here is the app's rather than the system's, for the reason
/// `ProjectSheet` says out loud: a `Picker` brings AppKit's bezel and a default
/// `Button` brings AppKit's accent blue, and three of those in a row are the
/// loudest thing in a window that is otherwise all Nod's own colours.
struct BeatEditor: View {
    enum Mode: Identifiable, Equatable {
        case create
        case edit(Beat)

        var id: String {
            switch self {
            case .create: "new"
            case let .edit(beat): beat.id.uuidString
            }
        }

        var beat: Beat? {
            if case let .edit(beat) = self { return beat }
            return nil
        }
    }

    let mode: Mode

    @EnvironmentObject private var beats: BeatStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var prompt: String
    @State private var cadence: Beat.Cadence
    @State private var hour: Int
    @State private var minute: Int
    @State private var weekday: Int
    @State private var dayOfMonth: Int
    @State private var enabled: Bool
    @State private var isDeleting = false
    @FocusState private var titleFocused: Bool
    @FocusState private var promptFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        let beat = mode.beat
        _title = State(initialValue: beat?.title ?? "")
        _prompt = State(initialValue: beat?.prompt ?? "")
        _cadence = State(initialValue: beat?.cadence ?? .weekdays)
        _hour = State(initialValue: beat?.hour ?? 9)
        _minute = State(initialValue: beat?.minute ?? 0)
        _weekday = State(initialValue: beat?.weekday ?? 1)
        _dayOfMonth = State(initialValue: beat?.dayOfMonth ?? 1)
        _enabled = State(initialValue: beat?.enabled ?? true)
    }

    private var isAsked: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            HStack(alignment: .top, spacing: 0) {
                settings
                    .frame(width: 214, alignment: .leading)
                Divider().overlay(Theme.Palette.border)
                ask
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.Palette.border)
            footer
        }
        .frame(width: 560)
        .background(WindowBackdrop().ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.beat == nil ? "New beat" : "Edit beat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Asked on a schedule, answered where you'll see it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { dismiss() } label: {
                Image("nc-xmark")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.muted)
            }
            .buttonStyle(.plain)
            .linkCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Name")
                titleField
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Schedule")
                SegmentedControl(selection: $cadence, options: Beat.Cadence.allCases) { option in
                    switch option {
                    case .daily: "Daily"
                    case .weekdays: "Weekdays"
                    case .weekly: "Weekly"
                    case .monthly: "Monthly"
                    }
                }
                HStack(spacing: 6) {
                    if cadence == .weekly {
                        menu(BeatSchedule.weekdayName(weekday)) {
                            ForEach(1 ... 7, id: \.self) { day in
                                Button(BeatSchedule.weekdayName(day)) { weekday = day }
                            }
                        }
                    }
                    if cadence == .monthly {
                        // Capped at the 28th: a beat set for the 30th would
                        // silently skip February.
                        menu(BeatSchedule.ordinal(dayOfMonth)) {
                            ForEach(1 ... 28, id: \.self) { day in
                                Button(BeatSchedule.ordinal(day)) { dayOfMonth = day }
                            }
                        }
                    }
                    menu(String(format: "%02d", hour), icon: "nc-stopwatch") {
                        ForEach(0 ... 23, id: \.self) { value in
                            Button(String(format: "%02d", value)) { hour = value }
                        }
                    }
                    menu(String(format: "%02d", minute)) {
                        ForEach([0, 15, 30, 45], id: \.self) { value in
                            Button(String(format: "%02d", value)) { minute = value }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if mode.beat != nil {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Active")
                    HStack(spacing: 8) {
                        Text(enabled ? "Asking on schedule" : "Paused — asks nothing")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.72))
                        Spacer(minLength: 0)
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                            .nodSwitch()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Ask")
            Text("Reads your sessions, screen record and tools. Never writes to them.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            promptField
            if let error = beats.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(BeatSchedule.describe(cadence: cadence, hour: hour, minute: minute, weekday: weekday, dayOfMonth: dayOfMonth)
                + " · runs on this Mac when it's awake")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.ink.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func menu(_ title: String, icon: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        Menu {
            content()
        } label: {
            MenuTrigger(title: title, icon: icon)
        }
        .plainMenuChrome()
        .fixedSize()
    }

    private var titleField: some View {
        TextField("Morning brief", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.Palette.ink)
            .focused($titleFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fieldSurface(focused: titleFocused))
    }

    /// A `TextEditor` has no placeholder of its own, and an empty box under a
    /// label reading "Ask" is the one place a person needs the example most.
    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if prompt.isEmpty {
                Text("What did I leave unfinished yesterday?")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(height: 136)
        }
        .background(fieldSurface(focused: promptFocused))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if mode.beat != nil {
                Button(isDeleting ? "Deleting…" : "Delete", action: delete)
                    .font(.system(size: 12.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.danger)
                    .linkCursor()
                    .disabled(isDeleting)
            }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .font(.system(size: 12.5))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.muted)
                .keyboardShortcut(.cancelAction)
            Button(action: save) {
                Text(mode.beat == nil ? "Create beat" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!isAsked)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func fieldSurface(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
            .fill(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .stroke(
                        focused ? Theme.Palette.borderStrong : Theme.Palette.border,
                        lineWidth: focused ? 1 : 0.5
                    )
            )
    }

    private func save() {
        Task {
            if var existing = mode.beat {
                existing.title = title
                existing.prompt = prompt
                existing.cadence = cadence
                existing.hour = hour
                existing.minute = minute
                existing.weekday = weekday
                existing.dayOfMonth = dayOfMonth
                existing.enabled = enabled
                await beats.update(existing)
            } else {
                await beats.create(
                    title: title,
                    prompt: prompt,
                    cadence: cadence,
                    hour: hour,
                    minute: minute,
                    weekday: weekday,
                    dayOfMonth: dayOfMonth
                )
            }
            dismiss()
        }
    }

    private func delete() {
        guard let beat = mode.beat else { return }
        isDeleting = true
        Task {
            await beats.delete(beat.id)
            dismiss()
        }
    }
}

#if DEBUG
    #Preview("New beat") {
        BeatEditor(mode: .create)
            .environmentObject(BeatStore(supabase: nil, auth: nil))
    }
#endif
