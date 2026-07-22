import AppKit
import SwiftUI

/// Privacy controls for screen reading: everything installed is listed, and the
/// user switches off whatever Nod must never look inside.
///
/// A list-with-switches rather than an add-to-blocklist flow, because the
/// question a user actually has is "what *can* it see?" — and only an
/// exhaustive list answers that.
struct ScreenPrivacySection: View {
    @ObservedObject var exclusions: ScreenExclusions
    var screenContext: ScreenContextService?
    @AppStorage(ScreenContextDefaults.enabledKey) private var ambientEnabled = false
    @AppStorage(ScreenContextDefaults.retentionDaysKey) private var retentionDays = ScreenContextDefaults.defaultRetentionDays
    @State private var scope: Scope = .apps
    @State private var installedApps: [InstalledApp] = []
    @State private var appQuery = ""
    @State private var websiteDraft = ""
    @State private var showsCategories = true

    private enum Scope: String, CaseIterable, Identifiable {
        case apps, websites

        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ambientContextCard
            tabs
            switch scope {
            case .apps: appsPane
            case .websites: websitesPane
            }
        }
        .task {
            guard installedApps.isEmpty else { return }
            installedApps = await Task.detached(priority: .userInitiated) { InstalledApps.load() }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Privacy controls")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Control what Nod can see while a meeting records. Excluded apps and sites are never read.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one switch in Nod that widens what it reads beyond a recording, so
    /// it states the trade in the row itself rather than in a policy the user
    /// will not open.
    private var ambientContextCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "sparkles.rectangle.stack",
                title: "Ambient context",
                subtitle: "Let Nod read the window you're working in, so you can ask about what you were doing — "
                    + "not just what was said. Off by default. Excluded apps and sites are never read."
            ) {
                Toggle("", isOn: $ambientEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: ambientEnabled) { _ in screenContext?.refresh() }
            }

            if ambientEnabled {
                SettingsRowDivider()
                SettingsRow(
                    icon: "clock.arrow.circlepath",
                    title: "Keep for",
                    subtitle: "Older context is deleted automatically, on the server, even if you never open Nod again."
                ) {
                    Picker("", selection: $retentionDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            tab(.apps, title: "Exclude apps", count: exclusions.apps.count)
            tab(.websites, title: "Exclude websites", count: exclusions.websiteRuleCount)
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
            Text("\(title) (\(count))")
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

    // MARK: - Apps

    private var appsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search applications…", text: $appQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            SettingsCard {
                if filteredApps.isEmpty {
                    SettingsRow(icon: "macwindow", title: emptyAppsTitle, subtitle: nil) { EmptyView() }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                                if index > 0 { SettingsRowDivider() }
                                appRow(app)
                            }
                        }
                    }
                    .frame(height: 300)
                }
            }
        }
    }

    private var emptyAppsTitle: String {
        installedApps.isEmpty ? "Looking for installed apps…" : "No apps match “\(appQuery)”"
    }

    private var filteredApps: [InstalledApp] {
        installedApps.filter { InstalledApps.matches($0, query: appQuery) }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(app.name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 12)
            Toggle("", isOn: binding(for: app))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { exclusions.excludes(app) },
            set: { exclusions.setExcluded($0, for: app) }
        )
    }

    // MARK: - Websites

    private var websitesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showsCategories) {
                VStack(spacing: 8) {
                    ForEach(WebsiteCategory.allCases) { category in
                        categoryCard(category)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Exclude by category (\(exclusions.categories.count))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            customSites
        }
    }

    private func categoryCard(_ category: WebsiteCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(category.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding(for: category))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private func binding(for category: WebsiteCategory) -> Binding<Bool> {
        Binding(
            get: { exclusions.categories.contains(category) },
            set: { exclusions.setExcluded($0, for: category) }
        )
    }

    private var customSites: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Specific sites")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)

            SettingsCard {
                if exclusions.websites.isEmpty {
                    SettingsRow(icon: "globe", title: "No sites added", subtitle: nil) { EmptyView() }
                } else {
                    ForEach(Array(exclusions.websites.enumerated()), id: \.element) { index, site in
                        if index > 0 { SettingsRowDivider() }
                        SettingsRow(icon: "globe", title: site, subtitle: nil) {
                            Button {
                                exclusions.removeWebsite(site)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.Palette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("bank.com", text: $websiteDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(addWebsite)
                Button("Add", action: addWebsite)
                    .disabled(websiteDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Matching is on the browser window title, so a tab that never names
            // the site slips through. Say so rather than imply a guarantee.
            Text("Sites are matched by window title. To be certain, exclude the browser itself.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addWebsite() {
        guard exclusions.excludeWebsite(websiteDraft) else { return }
        websiteDraft = ""
    }
}

#Preview {
    ScreenPrivacySection(exclusions: ScreenExclusions(defaults: UserDefaults(suiteName: "preview") ?? .standard))
        .padding()
        .frame(width: 460)
}
