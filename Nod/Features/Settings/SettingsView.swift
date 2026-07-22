import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey: HotkeyManager
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
    private let connections: ConnectionService?
    private let modeStore: ModeStore?
    private let referral: ReferralService?
    private let screenExclusions: ScreenExclusions?
    private let screenContext: ScreenContextService?

    init(
        hotkey: HotkeyManager,
        profileStore: ProfileStore? = nil,
        panelSharing: PanelSharingPreference? = nil,
        billing: BillingService? = nil,
        entitlements: EntitlementService? = nil,
        granolaImporter: GranolaImporter? = nil,
        auth: AuthService? = nil,
        accountExport: AccountExportService? = nil,
        connections: ConnectionService? = nil,
        modeStore: ModeStore? = nil,
        referral: ReferralService? = nil,
        screenExclusions: ScreenExclusions? = nil,
        screenContext: ScreenContextService? = nil,
        focusSubscription: Bool = false,
        focusModes: Bool = false
    ) {
        _hotkey = ObservedObject(wrappedValue: hotkey)
        self.profileStore = profileStore
        self.panelSharing = panelSharing
        self.billing = billing
        self.entitlements = entitlements
        self.granolaImporter = granolaImporter
        self.auth = auth
        self.accountExport = accountExport
        self.connections = connections
        self.modeStore = modeStore
        self.referral = referral
        self.screenExclusions = screenExclusions
        self.screenContext = screenContext
        _tab = State(initialValue: focusSubscription ? .subscription : (focusModes ? .modes : .profile))
    }

    /// Left-rail categories. Each maps to one detail pane.
    private enum Tab: String, CaseIterable, Identifiable {
        case profile, subscription, rewards, general, modes, connections, shortcuts, privacy
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .profile: "Profile"
            case .subscription: "Subscription"
            case .rewards: "Rewards"
            case .general: "General"
            case .modes: "Modes"
            case .connections: "Connections"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy"
            }
        }

        var icon: String {
            switch self {
            case .profile: "person.crop.circle"
            case .subscription: "creditcard"
            case .rewards: "gift"
            case .general: "gearshape"
            case .modes: "square.stack.3d.up"
            case .connections: "puzzlepiece.extension"
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
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenModes)) { _ in
            tab = .modes
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
                case .rewards: rewardsPane
                case .general: generalPane
                case .modes: modesPane
                case .connections: connectionsPane
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

            if let panelSharing {
                ScreenShareSettingsSection(pref: panelSharing)
            }

            if let granolaImporter, granolaImporter.isGranolaInstalled {
                GranolaImportSection(importer: granolaImporter)
            }

            #if DEBUG
                demoModeCard
            #endif
        }
    }

    #if DEBUG
        /// Recording aid — fills the app with sample meetings and swallows every
        /// DB read/write, so the whole workflow can be filmed without touching
        /// Supabase. DEBUG-only: neither this card nor `DemoData` compile into
        /// Release, so it can never reach the App Store build. Relaunches so the
        /// stores reseed cleanly regardless of what's cached.
        private var demoModeCard: some View {
            SettingsCard {
                SettingsRow(
                    icon: "wand.and.stars",
                    title: "Demo mode",
                    subtitle: "Fill Nod with sample meetings for a recording. Nothing is read from or written to the database. Toggling relaunches Nod."
                ) {
                    Toggle("", isOn: demoBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.Palette.violet)
                }
            }
        }

        private var demoBinding: Binding<Bool> {
            Binding(
                get: { DemoMode.isEnabled },
                set: { newValue in
                    DemoMode.set(newValue)
                    Self.relaunch()
                }
            )
        }

        private static func relaunch() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        Log.ui.error("demo relaunch failed: \(error.localizedDescription)")
                        return
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    #endif

    @ViewBuilder
    private var modesPane: some View {
        if let modeStore {
            ModesSettingsSection(store: modeStore)
        } else {
            Text("Meeting modes are unavailable right now.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
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
            SettingsRowDivider()
            SettingsRow(
                icon: "magnifyingglass",
                title: "Search & ask",
                subtitle: "Open the quick panel from any app to search your sessions or ask across all of them."
            ) {
                HotkeyRecorderView(hotkey: hotkey, action: .openLauncher)
            }
        }
    }

    @ViewBuilder
    private var rewardsPane: some View {
        if let referral, let entitlements {
            RewardsSection(service: referral, entitlements: entitlements)
        } else {
            Text("Sign in to see your referral rewards.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    @ViewBuilder
    private var connectionsPane: some View {
        if let connections {
            ConnectionsSection(service: connections)
        } else {
            Text("Sign in to connect Nod to your AI.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    @ViewBuilder
    private var privacyPane: some View {
        if let auth, let accountExport {
            VStack(alignment: .leading, spacing: 20) {
                if let screenExclusions, let screenContext {
                    ScreenPrivacySection(exclusions: screenExclusions, screenContext: screenContext)
                }
                AccountDataSection(auth: auth, export: accountExport)
            }
        } else {
            Text("Sign in to manage your data.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
        }
    }
}

#Preview {
    SettingsView(hotkey: HotkeyManager())
}
