import SwiftUI

/// One-tap migration off Granola — imports past meetings' transcripts from
/// Granola's offline cache. Only mounted when the cache exists on disk.
struct GranolaImportSection: View {
    @ObservedObject var importer: GranolaImporter

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-inbox-arrow-down",
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

/// Whether Nod offers to record a call it sees starting, and the apps it has
/// been told to stay quiet about.
///
/// The subtitle says what is read, not just what the feature does: this is the
/// one setting that looks at another app's windows outside a recording, and a
/// user who reads only the row should still know that.
struct MeetingDetectionSection: View {
    @ObservedObject var preference: MeetingDetectionPreference

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-video",
                title: "Detect meetings automatically",
                subtitle: "When a Zoom, Meet, Teams or Webex call starts, Nod offers to record it — "
                    + "and wraps up on its own when the call ends. Reads only which conferencing app is "
                    + "running and its window title; nothing is stored."
            ) {
                Toggle("", isOn: $preference.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if !preference.mutedApps.isEmpty {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-bell-slash",
                    title: "Never offered",
                    subtitle: "Nod stays quiet for calls in these apps."
                ) {
                    HStack(spacing: 6) {
                        ForEach(preference.mutedApps, id: \.rawValue) { app in
                            RemovablePill(
                                title: app.displayName,
                                removeHelp: "Detect \(app.displayName) calls again"
                            ) {
                                preference.setMuted(false, bundleID: app.rawValue)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Reading the calendar so a detected call can be named.
///
/// Its own switch rather than a line under meeting detection: this is the one
/// place in Settings that asks for a system grant the app can work without, and
/// the row has to be able to say what it is for before the prompt appears —
/// a macOS permission dialog that arrives unexplained gets refused.
struct CalendarSettingsSection: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-calendar",
                title: "Tell me when a meeting starts",
                subtitle: "Nod speaks up when something in your calendar is about to begin, names who it is "
                    + "with, and offers to record it. It also uses the invitation to tell speakers apart. "
                    + "Reads your Mac's own calendar, on this Mac — no account is connected, nothing stored."
            ) {
                Toggle("", isOn: $calendar.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            // The switch on its own is not the whole story: it says what the user
            // wants, and macOS separately decides whether Nod may. Whenever those
            // two disagree the row says so and offers the way out — without it
            // the switch reads "on" while nothing works and nothing explains why.
            if calendar.isEnabled, calendar.status != .authorized {
                SettingsRowDivider()
                if calendar.status == .denied { blockedRow } else { notAskedRow }
            }
        }
    }

    private var blockedRow: some View {
        SettingsRow(
            icon: "nc-triangle-warning",
            title: "macOS is blocking calendar access",
            subtitle: "Nod can't read your calendar until you allow it in System Settings → Privacy & Security → Calendars."
        ) {
            Button("Open Settings", action: calendar.openSystemSettings)
                .controlSize(.small)
        }
    }

    /// macOS has never been asked — normally because the prompt was dismissed or
    /// Nod was quit before it was answered. It only ever appears once on its
    /// own, so there has to be a way to ask for it again.
    private var notAskedRow: some View {
        SettingsRow(
            icon: "nc-hand",
            title: "macOS hasn't been asked yet",
            subtitle: "Nod needs your permission before it can read the calendar on this Mac."
        ) {
            Button("Allow access") {
                Task { await calendar.ensureAccess() }
            }
            .controlSize(.small)
        }
    }
}

/// What Nod puts on screen at launch. Default is the main window alone: the
/// floating panel arriving by itself, over whatever the user was doing, reads
/// as "I've already started recording".
struct LaunchBehaviorSection: View {
    @ObservedObject var behavior: LaunchBehavior

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-window-pointer",
                title: "When Nod starts",
                subtitle: behavior.mode.detail
            ) {
                Picker("", selection: $behavior.mode) {
                    ForEach(LaunchBehavior.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
        }
    }
}

struct ScreenShareSettingsSection: View {
    @ObservedObject var pref: PanelSharingPreference

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-stack-perspective",
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

/// The General pane, lifted out of `SettingsView`: it is the longest of the
/// panes and the one that keeps growing, and the window shell's job is choosing
/// which pane to show, not being one.
struct GeneralSettingsPane: View {
    let meetingDetection: MeetingDetectionPreference?
    let calendar: CalendarService?
    let launchBehavior: LaunchBehavior?
    let panelSharing: PanelSharingPreference?
    let granolaImporter: GranolaImporter?
    let demoPlayback: DemoPlayback?
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting = MeetingLanguagePromptDefaults.defaultValue
    @AppStorage(UISound.defaultsKey) private var soundsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meetingDetection {
                MeetingDetectionSection(preference: meetingDetection)
            }
            if let calendar {
                CalendarSettingsSection(calendar: calendar)
            }
            if let launchBehavior {
                LaunchBehaviorSection(behavior: launchBehavior)
            }
            if let demoPlayback {
                DemoSettingsSection(playback: demoPlayback)
            }
            SettingsCard {
                SettingsRow(
                    icon: "nc-earth",
                    title: "Confirm Nod language before each meeting",
                    subtitle: "Show a quick check for the language Nod uses in summaries and answers. Turn off to start straight away."
                ) {
                    Toggle("", isOn: $confirmLanguageBeforeMeeting)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.Palette.violet)
                }
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-volume-up",
                    title: "Sound effects",
                    subtitle: "A quiet cue when a meeting starts, when a recap is ready, and when Nod is about to stop on its own. Nod stays silent while it records."
                ) {
                    Toggle("", isOn: $soundsEnabled)
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
                resetFirstRunCard
            #endif
        }
    }

    #if DEBUG
        /// Replays the first-run experience without touching the account: the
        /// onboarding flag, the consent gate and our "we've prompted for Screen
        /// Recording" flag are all device-local. Meetings, profile and
        /// subscription live on the server and are untouched.
        ///
        /// The OS grants themselves are not ours to revoke — `tccutil reset
        /// ScreenCapture com.example.nod` does that, with Nod quit.
        private var resetFirstRunCard: some View {
            SettingsCard {
                SettingsRow(
                    icon: "nc-arrow-dotted-rotate-anticlockwise",
                    title: "Reset first run",
                    subtitle: "Replay onboarding and the consent disclaimer on the next launch. Local flags only — no meetings, profile or subscription data is touched. Relaunches Nod."
                ) {
                    Button {
                        OnboardingState.resetPersistedStatus()
                        ConsentPreference.resetPersistedGate()
                        PermissionManager.resetPersistedScreenPrompt()
                        Self.relaunch()
                    } label: {
                        Text("Reset")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.GlassButton.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .glassButtonSurface(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    #endif

    #if DEBUG
        /// Recording aid — fills the app with sample meetings and swallows every
        /// DB read/write, so the whole workflow can be filmed without touching
        /// Supabase. DEBUG-only: neither this card nor `DemoData` compile into
        /// Release, so it can never reach the App Store build. Relaunches so the
        /// stores reseed cleanly regardless of what's cached.
        private var demoModeCard: some View {
            SettingsCard {
                SettingsRow(
                    icon: "nc-wand-sparkle",
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
}
