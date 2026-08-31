import SwiftUI

/// How much a connected product may be reached without asking first.
///
/// In Privacy rather than Integrations: the question is not which products are
/// connected but what may leave the Mac unattended, which is what the rest of
/// this pane answers.
struct ToolApprovalSection: View {
    @ObservedObject var preference: ToolApprovalPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Asking before acting")
            SettingsCard {
                ForEach(Array(ToolApproval.allCases.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Divider().overlay(Theme.Palette.border)
                    }
                    row(option)
                }
            }
            // Said here rather than left to the card: the reassurance is the
            // reason the looser option is safe to pick, and somebody reading
            // the row is deciding exactly that.
            Text("Creating, sending or changing anything always asks, whichever you choose.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.horizontal, 2)

            // Whatever was allowed from a card, listed where it can be taken
            // back. A choice made in passing that can only be unmade by
            // finding the same card again is not a choice anybody keeps.
            if !preference.alwaysAllowed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Allowed without asking")
                    SettingsCard {
                        ForEach(preference.alwaysAllowed.sorted { $0.displayName < $1.displayName }) { provider in
                            HStack(spacing: 9) {
                                ProviderMark(provider: provider, size: 14)
                                Text(provider.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.Palette.ink)
                                Spacer(minLength: 0)
                                Button("Ask again") { preference.stopAllowing(provider) }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Theme.Palette.muted)
                                    .buttonStyle(.plain)
                                    .linkCursor()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func row(_ option: ToolApproval) -> some View {
        Button {
            preference.approval = option
        } label: {
            let isChosen = preference.approval == option
            HStack(alignment: .top, spacing: 10) {
                // A check on the chosen one and an empty slot on the others.
                // Nucleo has no hollow circle, and `design-system.md` forbids
                // reaching for an SF Symbol when it doesn't — so the choice is
                // carried by the check and the row's own fill, not by a glyph
                // that would have to be invented.
                Image("nc-circle-check")
                    .icon(15)
                    .foregroundStyle(Theme.Palette.ink)
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(option.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isChosen ? Theme.Palette.surfaceStrong : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}
