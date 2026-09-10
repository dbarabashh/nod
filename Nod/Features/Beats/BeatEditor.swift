import Supabase
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
    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var prompt: String
    @State private var cadence: Beat.Cadence
    @State private var hour: Int
    @State private var minute: Int
    @State private var weekday: Int
    @State private var dayOfMonth: Int
    @State private var enabled: Bool
    /// Nil is "every connected product", which is what a beat reads unless
    /// the person narrows it here.
    @State private var providers: Set<IntegrationProvider>?
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
        _providers = State(initialValue: beat?.providers.map(Set.init))
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
                    .frame(width: 300, alignment: .leading)
                Divider().overlay(Theme.Palette.border)
                ask
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.Palette.border)
            footer
        }
        .frame(width: 672)
        .background(WindowBackdrop().ignoresSafeArea())
    }

    private var header: some View {
        SheetHeader(
            title: mode.beat == nil ? "New agent" : "Edit agent",
            subtitle: "Asked on a schedule, answered where you'll see it.",
            onClose: { dismiss() }
        )
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
                        Text("Run on schedule")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.graphite)
                        Spacer(minLength: 0)
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                            .nodSwitch()
                    }
                    if !enabled {
                        Text("Paused. It keeps this schedule and asks nothing until you switch it back on.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            Text("Reads your sessions, screen record and tools, and writes the answer back to you — never to them.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            promptField
            reads
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
            .fieldSurface(focused: titleFocused)
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
        .fieldSurface(focused: promptFocused)
    }

    private var footer: some View {
        SheetFooter(
            delete: mode.beat == nil ? nil : TitledAction(isDeleting ? "Deleting…" : "Delete", isEnabled: !isDeleting, action: delete),
            cancel: { dismiss() },
            primary: TitledAction(mode.beat == nil ? "Create agent" : "Save", isEnabled: isAsked, action: save)
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
                existing.providers = providers.map { Array($0).sorted { $0.rawValue < $1.rawValue } }
                await beats.update(existing)
            } else {
                await beats.create(
                    title: title,
                    prompt: prompt,
                    cadence: cadence,
                    hour: hour,
                    minute: minute,
                    weekday: weekday,
                    dayOfMonth: dayOfMonth,
                    providers: providers.map { Array($0).sorted { $0.rawValue < $1.rawValue } }
                )
            }
            dismiss()
        }
    }

    /// Whether the plan lets this account connect anything at all. Read from
    /// the entitlement the same way Settings → Integrations decides what to
    /// offer, so the two never disagree about a plan.
    private var planAllowsIntegrations: Bool {
        guard let entitlement = entitlements.entitlement else { return true }
        return entitlement.can(.integrationsCore) || entitlement.can(.integrationsAll)
    }

    /// Which connected products the beat may read. Every one is on until the
    /// person switches one off; a product connected later joins a beat that
    /// was never narrowed, and stays out of one that was. The last chip goes
    /// to Settings → Integrations, because the way to give a beat another
    /// product is to connect it, and that has to be findable from here.
    private var reads: some View {
        let linked = integrations.usable
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Reads", size: .compact)
            if !planAllowsIntegrations {
                HStack(spacing: 8) {
                    Text("Connected products are not included in your plan. This agent reads your sessions, screen record and calendar.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("See plans") { leave(for: .subscription) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.violet)
                        .linkCursor()
                }
            } else if linked.isEmpty {
                HStack(spacing: 8) {
                    Text("Nothing connected yet. Connect a product and this agent can read it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Connect a product") { leave(for: .integrations) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.violet)
                        .linkCursor()
                }
            } else {
                WrapRow(spacing: 6) {
                    ForEach(linked, id: \.self) { product in
                        let isOn = providers?.contains(product) ?? true
                        Button {
                            // Judged against the chips on screen: a slug for
                            // a product since disconnected must not keep the
                            // beat narrowed once every visible chip is on.
                            var chosen = (providers ?? Set(linked)).intersection(linked)
                            if isOn { chosen.remove(product) } else { chosen.insert(product) }
                            providers = chosen == Set(linked) ? nil : chosen
                        } label: {
                            HStack(spacing: 5) {
                                ProviderMark(provider: product, size: 12)
                                Text(product.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .fixedSize()
                            .foregroundStyle(isOn ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.45))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                    .fill(isOn ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                            .stroke(isOn ? Theme.Palette.borderStrong : Theme.Palette.border, lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .linkCursor()
                        .help(isOn ? "This agent may read \(product.displayName)" : "This agent will not read \(product.displayName)")
                    }
                    Button { leave(for: .integrations) } label: {
                        HStack(spacing: 4) {
                            Image("nc-plus").icon(9)
                            Text("Connect more")
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .fixedSize()
                        .foregroundStyle(Theme.Palette.violet)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .stroke(Theme.Palette.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                        )
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                    .help("Opens Settings → Integrations. Anything you connect there appears here.")
                }
                Text("Anything you connect later appears here. An agent that was never narrowed reads it too.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sheet cannot show Settings behind itself, so the way there is to
    /// close and land on the pane; what was typed is lost, which is why this
    /// is offered before the question rather than after a long one.
    private func leave(for pane: SettingsFocus.Pane) {
        dismiss()
        settingsFocus.open(pane)
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
    #Preview("New agent") {
        BeatEditor(mode: .create)
            .environmentObject(BeatStore(supabase: nil, auth: nil))
            .environmentObject(IntegrationService(supabase: nil))
            .environmentObject(
                EntitlementService(supabase: SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey))
            )
            .environmentObject(SettingsFocus())
    }
#endif
