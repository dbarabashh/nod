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
