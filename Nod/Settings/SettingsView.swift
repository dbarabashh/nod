import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey: HotkeyManager
    @AppStorage(ReplyContext.defaultsKey) private var replyContext: ReplyContext = .auto
    @AppStorage(SummaryTemplate.defaultsKey) private var summaryTemplate: SummaryTemplate = .auto
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting: Bool = MeetingLanguagePromptDefaults.defaultValue

    /// Optional so previews (and any future env-free mount) work without a
    /// live Supabase-backed store. nil → the profile section is omitted.
    private let profileStore: ProfileStore?
    private let panelSharing: PanelSharingPreference?
    private let billing: BillingService?
    private let entitlements: EntitlementService?
    private let granolaImporter: GranolaImporter?
    private let auth: AuthService?
    private let accountExport: AccountExportService?

    init(
        hotkey: HotkeyManager,
        profileStore: ProfileStore? = nil,
        panelSharing: PanelSharingPreference? = nil,
        billing: BillingService? = nil,
        entitlements: EntitlementService? = nil,
        granolaImporter: GranolaImporter? = nil,
        auth: AuthService? = nil,
        accountExport: AccountExportService? = nil,
        focusSubscription: Bool = false
    ) {
        _hotkey = ObservedObject(wrappedValue: hotkey)
        self.profileStore = profileStore
        self.panelSharing = panelSharing
        self.billing = billing
        self.entitlements = entitlements
        self.granolaImporter = granolaImporter
        self.auth = auth
        self.accountExport = accountExport
        _tab = State(initialValue: focusSubscription ? .subscription : .profile)
    }

    /// Left-rail categories. Each maps to one detail pane.
    private enum Tab: String, CaseIterable, Identifiable {
        case profile, subscription, general, suggestReply, shortcuts, privacy
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .profile: "Profile"
            case .subscription: "Subscription"
            case .general: "General"
            case .suggestReply: "Suggest reply"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy"
            }
        }

        var icon: String {
            switch self {
            case .profile: "person.crop.circle"
            case .subscription: "creditcard"
            case .general: "gearshape"
            case .suggestReply: "sparkles"
            case .shortcuts: "keyboard"
            case .privacy: "lock.shield"
            }
        }
    }

    @State private var tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.Palette.border)
            detail
        }
        .frame(width: 740, height: 560)
        .background(WindowBackdrop().ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenSubscription)) { _ in
            tab = .subscription
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ForEach(Tab.allCases) { item in
                navButton(item)
            }
            Spacer(minLength: 0)

            // Selectable so a user can copy it verbatim into a bug report.
            // The DEBUG badge only compiles into Debug builds — a visible cue
            // that this build talks to the sandbox branch, never shipped to prod.
            HStack(spacing: 6) {
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .textSelection(.enabled)
                #if DEBUG
                    Text("DEBUG")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(Theme.Palette.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Theme.Palette.warning.opacity(0.15)))
                #endif
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .padding(12)
        // Clear the traffic-light buttons that float over the transparent titlebar.
        .padding(.top, 28)
        .frame(width: 210, alignment: .top)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Nod \(version) (\(build))"
    }

    private func navButton(_ item: Tab) -> some View {
        let isSelected = tab == item
        return Button { tab = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.18) : .clear, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tab.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)

                switch tab {
                case .profile: profilePane
                case .subscription: subscriptionPane
                case .general: generalPane
                case .suggestReply: suggestReplyPane
                case .shortcuts: shortcutsPane
                case .privacy: privacyPane
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "globe",
                    title: "Confirm Nod language before each meeting",
                    subtitle: "Show a quick check for the language Nod uses in summaries and answers. Turn off to start straight away."
                ) {
                    Toggle("", isOn: $confirmLanguageBeforeMeeting)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.Palette.violet)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "list.bullet.rectangle",
                    title: "Summary style",
                    subtitle: summaryTemplate.settingsHint
                ) {
                    Picker("Summary style", selection: $summaryTemplate) {
                        ForEach(SummaryTemplate.allCases) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Theme.Palette.ink)
                    .fixedSize()
                }
            }

            if let panelSharing {
                ScreenShareSettingsSection(pref: panelSharing)
            }

            if let granolaImporter, granolaImporter.isGranolaInstalled {
                GranolaImportSection(importer: granolaImporter)
            }
        }
    }

    @ViewBuilder
    private var profilePane: some View {
        if let profileStore {
            ProfileSettingsSection(store: profileStore)
        } else {
            Text("Sign in to edit your profile.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    @ViewBuilder
    private var subscriptionPane: some View {
        if let billing, let entitlements {
            PaywallView(billing: billing, entitlements: entitlements)
        } else {
            Text("Sign in to manage your subscription.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    private var suggestReplyPane: some View {
        SettingsCard {
            SettingsRow(
                icon: "sparkles",
                title: "Conversation type",
                subtitle: replyContext.settingsHint
            ) {
                Picker("Conversation type", selection: $replyContext) {
                    ForEach(ReplyContext.allCases) { context in
                        Text(context.displayName).tag(context)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.Palette.ink)
                .fixedSize()
            }
        }
    }

    private var shortcutsPane: some View {
        SettingsCard {
            SettingsRow(
                icon: "bubble.left.and.bubble.right",
                title: "Suggest reply",
                subtitle: "Get a real-time reply suggestion during a meeting, in any app. Avoid ⌘S — every app uses it for Save."
            ) {
                HotkeyRecorderView(hotkey: hotkey, action: .suggestReply)
            }
            SettingsRowDivider()
            SettingsRow(
                icon: "macwindow",
                title: "Show / hide panel",
                subtitle: "Toggle the floating panel from anywhere, even when another app is focused. Avoid ⌘H — macOS reserves it."
            ) {
                HotkeyRecorderView(hotkey: hotkey, action: .togglePanel)
            }
        }
    }

    @ViewBuilder
    private var privacyPane: some View {
        if let auth, let accountExport {
            AccountDataSection(auth: auth, export: accountExport)
        } else {
            Text("Sign in to manage your data.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }
}

/// GDPR data-rights surface: export everything as JSON (Art. 15 / 20) and
/// permanently delete the account (Art. 17). Both call Edge Functions that do
/// the real work server-side; this view is just the affordance + confirmation.
private struct AccountDataSection: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var export: AccountExportService

    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "square.and.arrow.up",
                    title: "Export my data",
                    subtitle: exportSubtitle
                ) {
                    Button(action: { Task { await export.export() } }) {
                        Text(isExporting ? "Exporting…" : "Export")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.GlassButton.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .glassButtonSurface(Capsule(style: .continuous))
                            .opacity(isExporting ? 0.7 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "trash",
                    title: "Delete account",
                    subtitle: deleteSubtitle
                ) {
                    Button(action: { confirmingDelete = true }) {
                        Text(isDeleting ? "Deleting…" : "Delete account…")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.Palette.danger)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .stroke(Theme.Palette.danger.opacity(0.5), lineWidth: 1)
                            )
                            .opacity(isDeleting ? 0.7 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
            }
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { delete() }
        } message: {
            Text(
                "This permanently deletes your account and all your meetings, transcripts, summaries, chats, and profile. This can't be undone. Export your data first if you want a copy."
            )
        }
    }

    private var isExporting: Bool {
        export.state == .exporting
    }

    private var exportSubtitle: String {
        switch export.state {
        case .idle, .exporting:
            "Download everything Nod holds about you — meetings, transcripts, summaries, chats, profile, and account data — as one JSON file."
        case .done:
            "Saved. Your data export is a complete, machine-readable copy of everything Nod holds about you."
        case let .failed(message):
            message
        }
    }

    private var deleteSubtitle: String {
        if let deleteError {
            return deleteError
        }
        return "Permanently erase your account and all associated data. Audio is never stored; everything else is deleted within seconds. This can't be undone."
    }

    private func delete() {
        isDeleting = true
        deleteError = nil
        Task {
            do {
                try await auth.deleteAccount()
            } catch {
                deleteError = "Couldn't delete your account. Please try again or email dbarabashdev@gmail.com."
            }
            isDeleting = false
        }
    }
}

/// One-tap migration off Granola — imports past meetings' transcripts from
/// Granola's offline cache. Only mounted when the cache exists on disk.
private struct GranolaImportSection: View {
    @ObservedObject var importer: GranolaImporter

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "square.and.arrow.down",
                title: "Import from Granola",
                subtitle: subtitle
            ) {
                Button(action: { Task { await importer.importFromCache() } }) {
                    Text(isImporting ? "Importing…" : "Import")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .glassButtonSurface(Capsule(style: .continuous))
                        .opacity(isImporting ? 0.7 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
        }
    }

    private var isImporting: Bool {
        importer.state == .importing
    }

    private var subtitle: String {
        switch importer.state {
        case .idle, .importing:
            "Bring your past Granola meetings' transcripts into Nod. Reads Granola's local cache only — no Granola account or internet needed."
        case let .done(imported):
            imported == 0
                ? "No meetings found in Granola's cache."
                : "Imported \(imported) meeting\(imported == 1 ? "" : "s") from Granola."
        case let .failed(message):
            message
        }
    }
}

private struct ScreenShareSettingsSection: View {
    @ObservedObject var pref: PanelSharingPreference

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "rectangle.on.rectangle",
                title: "Show Nod when you share your screen",
                subtitle: "Off by default, so Nod stays out of your screen shares and recordings. Turn it on to keep the panel visible — handy when you're presenting with Nod on screen or recording a walkthrough."
            ) {
                Toggle("", isOn: $pref.visibleWhenSharing)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.Palette.violet)
            }
        }
    }
}

// MARK: - Settings row primitives

/// A rounded card grouping one or more `SettingsRow`s, separated by
/// `SettingsRowDivider`. Matches the grouped look used across the app.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }
}

/// The app's standard grouped-surface container: a translucent fill with a
/// hairline border at the card radius. Shared by every settings card.
private extension View {
    func surfaceCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }
}

/// One setting: leading icon, title + subtitle, and a trailing control.
private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Hairline divider between rows in a `SettingsCard`, indented past the icon.
private struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .overlay(Theme.Palette.border)
            .padding(.leading, 58)
    }
}

/// "What Nod remembers about you" — the visible, editable face of the
/// always-on profile. Loads the current row on appear, seeds the fields
/// once, and upserts on Save with a transient confirmation.
private struct ProfileSettingsSection: View {
    @ObservedObject var store: ProfileStore

    @State private var name = ""
    @State private var preferences = ""
    @State private var seeded = false
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT NOD REMEMBERS ABOUT YOU")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)

            Text("Stored privately to your account; nothing here is shared.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Your name", placeholder: "Alex", text: $name)
            field(
                label: "What should Nod help you win at?",
                placeholder: "Track what people commit to me, surface risks early, and tell me how to make my point more persuasively",
                text: $preferences,
                helper: "Your edge in every conversation. Nod tailors each summary to it — so you follow through, stay on top, and get credit for your work.",
                multiline: true
            )

            saveRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .task {
            await store.load()
            seedIfNeeded()
        }
        .onReceive(store.$profile) { _ in seedIfNeeded() }
    }

    private var saveRow: some View {
        HStack(spacing: 10) {
            Button(action: save) {
                Text(saveState == .saving ? "Saving…" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .opacity(saveState == .saving ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(saveState == .saving)

            statusLabel
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch saveState {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.Palette.success)
                .transition(.opacity)
        case let .failed(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.danger)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>, helper: String? = nil, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            if let helper {
                Text(helper)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(multiline ? 2 ... 4 : 1 ... 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
        }
    }

    private func seedIfNeeded() {
        guard !seeded, let profile = store.profile else { return }
        name = profile.displayName
        preferences = profile.preferences
        seeded = true
    }

    private func save() {
        saveState = .saving
        Task {
            do {
                try await store.save(displayName: name, preferences: preferences)
                withAnimation { saveState = .saved }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if saveState == .saved { withAnimation { saveState = .idle } }
            } catch {
                withAnimation { saveState = .failed(error.localizedDescription) }
            }
        }
    }
}

#Preview {
    SettingsView(hotkey: HotkeyManager())
}
