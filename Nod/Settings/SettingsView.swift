import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey = HotkeyManager.shared
    @AppStorage(ReplyContext.defaultsKey) private var replyContext: ReplyContext = .auto
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting: Bool = MeetingLanguagePromptDefaults.defaultValue

    /// Optional so previews (and any future env-free mount) work without a
    /// live Supabase-backed store. nil → the profile section is omitted.
    private let profileStore: ProfileStore?
    private let panelSharing: PanelSharingPreference?

    init(profileStore: ProfileStore? = nil, panelSharing: PanelSharingPreference? = nil) {
        self.profileStore = profileStore
        self.panelSharing = panelSharing
    }

    /// Left-rail categories. Each maps to one detail pane.
    private enum Tab: String, CaseIterable, Identifiable {
        case profile, general, suggestReply, shortcuts
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .profile: "Profile"
            case .general: "General"
            case .suggestReply: "Suggest reply"
            case .shortcuts: "Shortcuts"
            }
        }

        var icon: String {
            switch self {
            case .profile: "person.crop.circle"
            case .general: "gearshape"
            case .suggestReply: "sparkles"
            case .shortcuts: "keyboard"
            }
        }
    }

    @State private var tab: Tab = .profile

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.Palette.border)
            detail
        }
        .frame(width: 740, height: 560)
        .background(WindowBackdrop().ignoresSafeArea())
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
            Text(Self.versionString)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .textSelection(.enabled)
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
                    .fill(isSelected ? Theme.Palette.violet.opacity(0.22) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .stroke(isSelected ? Theme.Palette.violet.opacity(0.45) : .clear, lineWidth: 0.5)
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
                case .general: generalPane
                case .suggestReply: suggestReplyPane
                case .shortcuts: shortcutsPane
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
                    title: "Confirm language before each meeting",
                    subtitle: "Show a quick language check when you start a meeting, so you don't record in the wrong language. Turn off to start straight away."
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
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
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
    SettingsView()
}
