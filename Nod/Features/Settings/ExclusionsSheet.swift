import SwiftUI

/// The full list of what Nod may and may not read, behind a door.
///
/// It used to be the Privacy page itself: two hundred apps with identical
/// switches, scrolling past everything that actually reassures anybody. The
/// list still has to be exhaustive — "what *can* it see?" has no honest answer
/// short of naming everything — but it is a thing you open to check, not the
/// first thing you meet.
struct ExclusionsSheet: View {
    @ObservedObject var exclusions: ScreenExclusions
    @ObservedObject var screenContext: ScreenContextService

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .apps

    private enum Scope: String, CaseIterable, Identifiable {
        case apps, websites

        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SettingsRowDivider(indent: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tabs
                    switch scope {
                    case .apps: ExcludedAppsPane(exclusions: exclusions, screenContext: screenContext)
                    case .websites: ExcludedSitesPane(exclusions: exclusions)
                    }
                }
                .padding(20)
            }
            SettingsRowDivider(indent: 0)
            footer
        }
        .frame(width: 560, height: 620)
        // The window this sits over is frosted glass; a flat fill made the
        // sheet the one opaque slab in the product.
        .background(WindowBackdrop())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What Nod may read")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Applies only while ambient context is on. A recording's own audio is never affected by this list.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            tab(.apps, title: "Apps", count: exclusions.apps.count)
            tab(.websites, title: "Websites", count: exclusions.websiteRuleCount)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surface)
        )
    }

    private func tab(_ value: Scope, title: String, count: Int) -> some View {
        Button {
            scope = value
        } label: {
            Text("\(title) · \(count) never read")
                .font(.system(size: 12, weight: scope == value ? .semibold : .regular))
                .foregroundStyle(scope == value ? Theme.Palette.ink : Theme.Palette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(scope == value ? Theme.Palette.surfaceStrong : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}
