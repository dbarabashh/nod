import SwiftUI

/// Arms the scripted demo and picks the story, without a `defaults write` and a
/// relaunch between takes.
///
/// It lives in Settings because that is where it gets used: a recording session
/// is half a dozen takes, and switching scenario or pace between them has to
/// cost one click. Nothing here fabricates data anywhere else in the app — the
/// script only ever drives the notch.
struct DemoSettingsSection: View {
    @ObservedObject var playback: DemoPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(
                    icon: "play.rectangle.on.rectangle",
                    title: "Scripted demo",
                    subtitle: "Start plays a fixed 60-second story instead of recording. Nothing is transcribed, sent, or saved."
                ) {
                    Toggle("", isOn: $playback.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if playback.isEnabled {
                    SettingsRowDivider()

                    SettingsRow(
                        icon: "list.bullet.rectangle",
                        title: "Scenario",
                        subtitle: "Every scenario follows the same beats — context found, insight, multi-tool workflow, follow-up booked, summary."
                    ) {
                        Picker("", selection: $playback.scenario) {
                            ForEach(DemoScenario.allCases) { scenario in
                                Text(scenario.displayName).tag(scenario)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }

                    SettingsRowDivider()

                    SettingsRow(
                        icon: "metronome",
                        title: "Pace",
                        subtitle: paceSubtitle
                    ) {
                        Slider(
                            value: $playback.pace,
                            in: DemoPlayback.paceRange,
                            step: 0.05
                        )
                        .frame(width: 190)
                    }
                }

                SettingsRowDivider()

                SettingsRow(
                    icon: "macbook",
                    title: "Preview without the notch",
                    subtitle: "Draw the surface the way every external display and every pre-2021 Mac sees it — a free-standing pill instead of a shape that continues the cut-out."
                ) {
                    Toggle("", isOn: $playback.previewWithoutNotch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if playback.isEnabled {
                Text("Press Start in the notch to play. The demo owns the surface until it finishes, so nothing else can interrupt a take.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var paceSubtitle: String {
        let seconds = Int((playback.scenario.duration * playback.pace).rounded())
        return "About \(seconds) seconds end to end. Slower gives each card longer to be read."
    }
}
