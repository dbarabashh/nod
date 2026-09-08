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
    @ObservedObject var permissions: PermissionManager

    /// One menu with every conferencing app Nod knows, ticked where it is
    /// excluded. A picker rather than a list of removable pills: the card that
    /// used to add to this list is gone, so without somewhere to *add* an app
    /// the setting could only ever empty itself.
    private var blockedByScreenRecordingRow: some View {
        SettingsRow(
            icon: "nc-triangle-warning",
            title: "macOS is blocking detection",
            subtitle: "Nod reads a conferencing app's window title to notice a call, and that needs Screen "
                + "Recording — the same permission it already uses to hear the other side."
        ) {
            Button("Open Settings", action: permissions.openScreenRecordingSettings)
                .controlSize(.small)
        }
    }

    private var excludedAppsMenu: some View {
        Menu {
            ForEach(ConferencingApp.products, id: \.rawValue) { app in
                Toggle(app.displayName, isOn: binding(for: app))
            }
        } label: {
            MenuTrigger(title: menuLabel)
        }
        .plainMenuChrome()
    }

    private var menuLabel: String {
        let muted = preference.mutedApps
        guard let first = muted.first else { return "None" }
        return muted.count == 1 ? first.displayName : "\(muted.count) apps"
    }

    private func binding(for app: ConferencingApp) -> Binding<Bool> {
        Binding(
            get: { app.bundleIDs.contains { preference.mutedBundleIDs.contains($0) } },
            set: { preference.setMuted($0, app: app) }
        )
    }

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
                    .nodSwitch()
                    .labelsHidden()
                    .controlSize(.small)
            }

            // The switch says what the user wants; macOS decides whether Nod
            // may. Window titles ride on the screen-recording grant, so without
            // it detection is silent for ever while this row still reads "on" —
            // the same lie the calendar row below exists to prevent.
            if preference.isEnabled, permissions.screenRecording != .authorized {
                SettingsRowDivider()
                blockedByScreenRecordingRow
            }

            SettingsRowDivider()
            SettingsRow(
                icon: "nc-bell-slash",
                title: "Excluded meeting apps",
                subtitle: "Nod won't offer to record calls in these apps."
            ) {
                excludedAppsMenu
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
                    .nodSwitch()
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

            // A switch that reads "off" while Nod is announcing meetings is a
            // switch nobody can trust. It governs this Mac's calendar; the
            // connected account is the other half of the same feature and turns
            // off where it was turned on.
            if calendar.hasAnySource, !calendar.isReadable {
                SettingsRowDivider()
                connectedAccountRow
            }
        }
    }

    private var connectedAccountRow: some View {
        SettingsRow(
            icon: "nc-link",
            title: "A connected calendar is already answering",
            subtitle: "This switch covers your Mac's own calendar. Nod is reading the account you connected "
                + "in Integrations, so it still knows which meeting is starting — disconnect it there to stop that."
        ) {
            EmptyView()
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

/// How eagerly Nod interrupts mid-meeting. A slider rather than a switch —
/// see `ProactivityPreference.Level` — because the real spectrum users want
/// isn't on/off, it's "a couple of nudges an hour" to "as often as useful".
struct ProactivitySettingsSection: View {
    @ObservedObject var preference: ProactivityPreference

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-bolt-lightning",
                title: "Proactivity",
                subtitle: "\(preference.level.title) — \(preference.level.detail)"
            ) {
                Slider(
                    value: levelBinding,
                    in: 0 ... Double(ProactivityPreference.Level.allCases.count - 1),
                    step: 1
                )
                .tint(Theme.Palette.violet)
                .frame(width: 190)
            }
        }
    }

    private var levelBinding: Binding<Double> {
        Binding(
            get: { Double(preference.level.rawValue) },
            set: { newValue in
                preference.level = ProactivityPreference.Level(rawValue: Int(newValue.rounded())) ?? .balanced
            }
        )
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
                    .nodSwitch()
            }
        }
    }
}

/// Which shape the capture surface takes. A segmented picker rather than a
/// toggle: neither option is "off", and a switch labelled "notch" would make the
/// panel read as its absence.
struct CaptureSurfaceSection: View {
    @ObservedObject var preference: CaptureSurfacePreference

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-laptop",
                title: "Capture surface",
                subtitle: preference.surface.detail
            ) {
                SegmentedControl(
                    selection: $preference.surface,
                    options: CaptureSurfacePreference.Surface.allCases,
                    title: \.title
                )
                .frame(width: 190)
            }
        }
    }
}

/// Which microphone Nod records from, for when no meeting is running —
/// `NotchMicControl` holds the same choice mid-meeting.
struct MicrophoneSettingsSection: View {
    @ObservedObject var audioCapture: AudioCaptureService

    var body: some View {
        SettingsCard {
            SettingsRow(icon: "nc-mic", title: "Microphone", subtitle: subtitle) {
                MicrophoneInputPicker(
                    devices: audioCapture.availableInputs,
                    selectedUID: audioCapture.preferredInputUID,
                    // Switching, not just storing: `switchInput` rebinds a live
                    // recording's engine, so a change mid-meeting takes effect
                    // on the next word rather than the next meeting.
                    onSelect: { uid in Task { await audioCapture.switchInput(to: uid) } }
                )
                .labelsHidden()
                .frame(width: 210)
            }
        }
    }

    private var subtitle: String {
        let devices = audioCapture.availableInputs
        guard let uid = audioCapture.preferredInputUID else {
            return devices.systemDefaultName.map { "Following macOS — currently \($0)." }
                ?? "Following whichever input macOS is set to."
        }
        guard let name = devices.name(forUID: uid) else {
            return "The microphone you picked isn't connected. Nod records from the system default until it's back."
        }
        return "Always records from \(name), whatever macOS switches to."
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
    let proactivity: ProactivityPreference?
    let granolaImporter: GranolaImporter?
    let demoPlayback: DemoPlayback?
    let captureSurface: CaptureSurfacePreference?
    let audioCapture: AudioCaptureService?
    let permissions: PermissionManager?
    let appearance: AppearancePreference?
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting = MeetingLanguagePromptDefaults.defaultValue
    @AppStorage(UISound.defaultsKey) private var soundsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Above the permissions card, which otherwise leads: a person who
            // came here because something broke is looking for the way to say
            // so, not for a switch.
            SupportSection()
            if let permissions {
                RecordingPermissionsSection(permissions: permissions)
            }
            if let appearance {
                AppearanceSection(preference: appearance)
            }
            if let meetingDetection, let permissions {
                MeetingDetectionSection(preference: meetingDetection, permissions: permissions)
            }
            if let calendar {
                CalendarSettingsSection(calendar: calendar)
            }
            if let proactivity {
                ProactivitySettingsSection(preference: proactivity)
            }
            if let captureSurface {
                CaptureSurfaceSection(preference: captureSurface)
            }
            if let audioCapture {
                MicrophoneSettingsSection(audioCapture: audioCapture)
            }
            if let launchBehavior {
                LaunchBehaviorSection(behavior: launchBehavior)
            }
            // Sandbox as well as Debug, because the sandbox build is the one
            // that gets installed on a second Mac and demoed from — a toggle
            // only reachable from Xcode is not reachable when it is wanted.
            //
            // Safe to widen, and only because the scripted demo is not the
            // fixture-serving `DemoMode`: `NotchModel.requestStart` returns
            // before it reaches a microphone, a lease or a write, so the row's
            // "nothing is transcribed, sent, or saved" is literally true rather
            // than enforced by swallowed writes. Release stays out.
            #if DEBUG || NOD_SANDBOX
                if let demoPlayback {
                    DemoSettingsSection(playback: demoPlayback)
                }
            #endif
            SettingsCard {
                SettingsRow(
                    icon: "nc-earth",
                    title: "Confirm Nod language before each session",
                    subtitle: "Show a quick check for the language Nod uses in summaries and answers. Turn off to start straight away."
                ) {
                    Toggle("", isOn: $confirmLanguageBeforeMeeting)
                        .labelsHidden()
                        .nodSwitch()
                }
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-volume-up",
                    title: "Sound effects",
                    subtitle: "A quiet cue when a meeting starts, when a recap is ready, and when Nod is about to stop on its own. Nod stays silent while it records."
                ) {
                    Toggle("", isOn: $soundsEnabled)
                        .labelsHidden()
                        .nodSwitch()
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
            #if DEBUG || NOD_SANDBOX
                resetFirstRunCard
            #endif
        }
    }

    // Sandbox as well as Debug. The sandbox build is how onboarding actually
    // gets exercised — it is a shipped-shape build on the sandbox database,
    // which is the whole point of having one — and without this the only way to
    // replay a first run was to build Debug from source. Deliberately narrower
    // than defining `DEBUG` for the configuration: that would switch on all 39
    // other `#if DEBUG` sites, demo mode and its fixture data among them.
    #if DEBUG || NOD_SANDBOX
        /// Replays the first-run experience without touching the account: the
        /// onboarding flag, the consent gate, the diagnostics answer, Today's
        /// put-off asks and the ambient switch are all device-local, and the
        /// microphone, Screen Recording and Accessibility grants are handed
        /// back to macOS with `tccutil`, so every card in the flow is asked
        /// for real. Meetings, profile and subscription live on the server
        /// and are untouched.
        private var resetFirstRunCard: some View {
            SettingsCard {
                SettingsRow(
                    icon: "nc-arrow-dotted-rotate-anticlockwise",
                    title: "Reset first run",
                    subtitle: "Replay onboarding on the next launch, with the microphone, Screen Recording, Accessibility and ambient context all asked again. Local flags only — no meetings, profile or subscription data is touched. Relaunches Nod."
                ) {
                    Button {
                        OnboardingState.resetPersistedStatus()
                        ConsentPreference.resetPersistedGate()
                        CrashReporting.resetPersistedChoice()
                        TodayNudge.resetPersistedDismissals()
                        ScreenContextDefaults.setEnabled(false)
                        PermissionManager.resetPersistedGrants()
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
                        .nodSwitch()
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

    #endif

    #if DEBUG || NOD_SANDBOX
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

#Preview("Microphone") {
    MicrophoneSettingsSection(audioCapture: AudioCaptureService())
        .padding()
        .frame(width: 560)
        .background(WindowBackdrop())
}
