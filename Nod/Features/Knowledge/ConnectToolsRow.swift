import SwiftUI

/// What Nod could also be reading, offered under the openers on the home
/// screen.
///
/// The composer's mark row only ever showed the products somebody had already
/// found, so a person who connected Slack on day one never learnt the calendar
/// was reachable at all. This is the other half.
struct ConnectToolsRow: View {
    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var settingsFocus: SettingsFocus

    /// Offered in declaration order, and only where a real mark ships — a chip
    /// wearing the stand-in glyph teaches nobody that Slack is reachable.
    /// Derived rather than listed: a hand-written copy of this was already
    /// wrong on the day it was written, offering Asana (no mark) and omitting
    /// HubSpot (has one).
    private var unlinked: [IntegrationProvider] {
        Array(
            IntegrationProvider.allCases
                .filter {
                    ProviderMark.ships.contains($0)
                        && !integrations.linked.contains($0)
                        // Offering a product an admin switched off is worse
                        // than saying nothing.
                        && !integrations.blockedByOrganization.contains($0)
                }
                .prefix(5)
        )
    }

    var body: some View {
        // Read once: the guard and the `ForEach` each used to run the filter.
        // `hasLoaded` short-circuits it — `linked` starts empty, so without
        // that every launch offers Slack to somebody who connected it months
        // ago, for as long as the first read takes.
        let unlinked = integrations.hasLoaded ? unlinked : []
        if !unlinked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nod can read these too")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                HStack(spacing: 6) {
                    ForEach(unlinked, id: \.self) { provider in
                        ChatSuggestionChip(text: provider.displayName, provider: provider) {
                            settingsFocus.open(.integrations)
                        }
                        .help("Connect \(provider.displayName) — Nod can then read it alongside your sessions")
                    }
                }
            }
        }
    }
}

#if DEBUG
    #Preview("Nothing connected") {
        ConnectToolsRow()
            .environmentObject(IntegrationService.preview())
            .environmentObject(SettingsFocus())
            .padding(20)
            .background(Theme.Palette.bg)
    }

    #Preview("Some connected") {
        ConnectToolsRow()
            .environmentObject(IntegrationService.preview(linked: [.slack, .linear]))
            .environmentObject(SettingsFocus())
            .padding(20)
            .background(Theme.Palette.bg)
    }
#endif
