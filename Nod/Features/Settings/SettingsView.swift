import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey: HotkeyManager

    /// Optional so previews (and any future env-free mount) work without a
    /// live Supabase-backed store. nil → the profile section is omitted.
    private let profileStore: ProfileStore?
    private let panelSharing: PanelSharingPreference?
    private let proactivity: ProactivityPreference?
    private let launchBehavior: LaunchBehavior?
    private let billing: BillingService?
    private let entitlements: EntitlementService?
    private let granolaImporter: GranolaImporter?
    private let auth: AuthService?
    private let accountExport: AccountExportService?
    private let connections: ConnectionService?
    private let integrations: IntegrationService?
    private let modeStore: ModeStore?
    private let referral: ReferralService?
    private let emailPreferences: EmailPreferenceService?
    private let productAnalytics: ProductAnalytics?
    private let screenExclusions: ScreenExclusions?
    private let screenContext: ScreenContextService?
    private let meetingDetection: MeetingDetectionPreference?
    private let calendar: CalendarService?
    private let demoPlayback: DemoPlayback?
    private let captureSurface: CaptureSurfacePreference?

    init(
        hotkey: HotkeyManager,
        profileStore: ProfileStore? = nil,
        panelSharing: PanelSharingPreference? = nil,
        proactivity: ProactivityPreference? = nil,
        launchBehavior: LaunchBehavior? = nil,
        billing: BillingService? = nil,
        entitlements: EntitlementService? = nil,
        granolaImporter: GranolaImporter? = nil,
        auth: AuthService? = nil,
        accountExport: AccountExportService? = nil,
        connections: ConnectionService? = nil,
        integrations: IntegrationService? = nil,
        modeStore: ModeStore? = nil,
        referral: ReferralService? = nil,
        emailPreferences: EmailPreferenceService? = nil,
        productAnalytics: ProductAnalytics? = nil,
        screenExclusions: ScreenExclusions? = nil,
        screenContext: ScreenContextService? = nil,
        meetingDetection: MeetingDetectionPreference? = nil,
        calendar: CalendarService? = nil,
        demoPlayback: DemoPlayback? = nil,
        captureSurface: CaptureSurfacePreference? = nil,
        focusSubscription: Bool = false,
        focusModes: Bool = false
    ) {
        _hotkey = ObservedObject(wrappedValue: hotkey)
        self.profileStore = profileStore
        self.panelSharing = panelSharing
        self.proactivity = proactivity
        self.launchBehavior = launchBehavior
        self.billing = billing
        self.entitlements = entitlements
        self.granolaImporter = granolaImporter
        self.auth = auth
        self.accountExport = accountExport
        self.connections = connections
        self.integrations = integrations
        self.modeStore = modeStore
        self.referral = referral
        self.emailPreferences = emailPreferences
        self.productAnalytics = productAnalytics
        self.screenExclusions = screenExclusions
        self.screenContext = screenContext
        self.meetingDetection = meetingDetection
        self.calendar = calendar
        self.demoPlayback = demoPlayback
        self.captureSurface = captureSurface
        _tab = State(initialValue: focusSubscription ? .subscription : (focusModes ? .modes : .general))
    }

    /// Left-rail categories, ordered by how often they're opened: the everyday
    /// knobs first, then the account and its money, then the data controls
    /// people come looking for rather than browse. `allCases` drives the rail,
    /// so this declaration order is the on-screen order.
    private enum Tab: String, CaseIterable, Identifiable {
        case general, modes, shortcuts, connections, integrations, profile, subscription, rewards, privacy
        var id: String {
            rawValue
        }

        /// One table rather than a switch per attribute, so a new tab spells its
        /// name once and the compiler still demands both halves.
        private var display: (title: String, icon: String) {
            switch self {
            case .general: ("General", "nc-gear-2")
            case .modes: ("Modes", "nc-layers-3")
            case .shortcuts: ("Shortcuts", "nc-keyboard")
            case .connections: ("Connections", "nc-puzzle-piece")
            case .integrations: ("Integrations", "nc-link")
            case .profile: ("Profile", "nc-user")
            case .subscription: ("Subscription", "nc-credit-card")
            case .rewards: ("Rewards", "nc-gift")
            case .privacy: ("Privacy", "nc-shield-check")
            }
        }

        var title: String {
            display.title
        }

        var icon: String {
            display.icon
        }

        /// The rail's single break: everyday settings above, the account and the
        /// data it holds below.
        var startsAccountGroup: Bool {
            self == .profile
        }
    }

    @State private var tab: Tab
    @EnvironmentObject private var focus: SettingsFocus

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.Palette.border)
            detail
        }
        // Sized by the window it's a section of — Settings is no longer a
        // fixed-size window of its own, and the main window draws the backdrop.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { applyPendingFocus() }
        .onChange(of: focus.request) { _ in applyPendingFocus() }
    }

    /// A deep link ("open Settings on Subscription") is raised before this pane
    /// mounts, so the request is read here rather than delivered as a
    /// notification to a view that didn't exist yet.
    private func applyPendingFocus() {
        switch focus.consume() {
        case .general: tab = .general
        case .subscription: tab = .subscription
        case .rewards: tab = .rewards
        case .modes: tab = .modes
        case .privacy: tab = .privacy
        case .profile: tab = .profile
        case nil: break
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
                if item.startsAccountGroup {
                    Divider()
                        .overlay(Theme.Palette.border)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
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
                Image(item.icon)
                    .icon(13)
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
                case .integrations: integrationsPane
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
        GeneralSettingsPane(
            meetingDetection: meetingDetection,
            calendar: calendar,
            launchBehavior: launchBehavior,
            panelSharing: panelSharing,
            proactivity: proactivity,
            granolaImporter: granolaImporter,
            demoPlayback: demoPlayback,
            captureSurface: captureSurface
        )
    }

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
                icon: "nc-window-pointer",
                title: "Show / hide panel",
                subtitle: "Toggle the floating panel from anywhere, even when another app is focused. Avoid ⌘H — macOS reserves it."
            ) {
                HotkeyRecorderView(hotkey: hotkey, action: .togglePanel)
            }
            SettingsRowDivider()
            SettingsRow(
                icon: "nc-magnifier",
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
            RewardsSection(service: referral, entitlements: entitlements, analytics: productAnalytics)
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
    private var integrationsPane: some View {
        if let integrations {
            IntegrationsSection(service: integrations)
        } else {
            Text("Sign in to connect Nod to your tools.")
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
                if let emailPreferences {
                    EmailPreferencesSection(preferences: emailPreferences)
                }
                if let productAnalytics {
                    ProductAnalyticsSection(analytics: productAnalytics)
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
        .environmentObject(SettingsFocus())
        .frame(width: 740, height: 560)
}
