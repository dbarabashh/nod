import SwiftUI

/// The two knobs that decide how Nod looks: its theme, and whether its windows
/// blur what is behind them.
struct AppearanceSection: View {
    @ObservedObject var preference: AppearancePreference

    @AppStorage(AppearanceDefaults.transparencyKey)
    private var isTransparencyEnabled = AppearanceDefaults.isTransparentByDefault
    @Environment(\.accessibilityReduceTransparency) private var isReducedBySystem

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-contrast",
                title: "Appearance",
                subtitle: preference.mode.detail
            ) {
                SegmentedControl(
                    selection: $preference.mode,
                    options: AppearancePreference.Mode.allCases,
                    title: \.title
                )
                .frame(width: 190)
            }

            SettingsRowDivider()

            SettingsRow(
                icon: "nc-transparency",
                title: "Transparent background",
                subtitle: transparencySubtitle
            ) {
                Toggle("", isOn: $isTransparencyEnabled)
                    .nodSwitch()
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(isReducedBySystem)
            }
        }
    }

    private var transparencySubtitle: String {
        isReducedBySystem
            ? "Off — macOS is set to reduce transparency in System Settings › Accessibility › Display."
            : "Nod's windows blur your desktop through them. Turn off for flat, solid backgrounds."
    }
}

#Preview {
    AppearanceSection(preference: AppearancePreference())
        .padding(24)
        .frame(width: 520)
        .background(Theme.Palette.bg)
}
