import SwiftUI

/// One-tap migration off Granola — imports past meetings' transcripts from
/// Granola's offline cache. Only mounted when the cache exists on disk.
struct GranolaImportSection: View {
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
                icon: "video.badge.waveform",
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
                    icon: "bell.slash",
                    title: "Never detected",
                    subtitle: "Calls in these apps are never offered."
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

/// What Nod puts on screen at launch. Default is the main window alone: the
/// floating panel arriving by itself, over whatever the user was doing, reads
/// as "I've already started recording".
struct LaunchBehaviorSection: View {
    @ObservedObject var behavior: LaunchBehavior

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "macwindow.on.rectangle",
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

/// The General pane, lifted out of `SettingsView`: it is the longest of the
/// panes and the one that keeps growing, and the window shell's job is choosing
/// which pane to show, not being one.
struct GeneralSettingsPane: View {
    let meetingDetection: MeetingDetectionPreference?
    let launchBehavior: LaunchBehavior?
    let panelSharing: PanelSharingPreference?
    let granolaImporter: GranolaImporter?
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting = MeetingLanguagePromptDefaults.defaultValue
    @AppStorage(UISound.defaultsKey) private var soundsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meetingDetection {
                MeetingDetectionSection(preference: meetingDetection)
            }
            if let launchBehavior {
                LaunchBehaviorSection(behavior: launchBehavior)
            }
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
                SettingsRowDivider()
                SettingsRow(
                    icon: "speaker.wave.2",
                    title: "Sound effects",
                    subtitle: "A quiet cue when a call is detected, when a recap is ready, and when Nod is about to stop on its own. Nod stays silent while it records."
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
}
