import SwiftUI

/// Every app on the Mac, split by whether Nod may read it.
struct ExcludedAppsPane: View {
    @ObservedObject var exclusions: ScreenExclusions
    @ObservedObject var screenContext: ScreenContextService

    @State private var installedApps: [InstalledApp] = []
    @State private var appQuery = ""
    /// Set by the app row's "Delete captured context" command, confirmed before
    /// it runs — deletion can't be undone, same rule as the sidebar's own
    /// delete menu (`AmbientContextSidebarRow`).
    @State private var pendingAppDeletion: ExcludedApp?

    var body: some View {
        appsPane
            .task {
                guard installedApps.isEmpty else { return }
                installedApps = await Task.detached(priority: .userInitiated) { InstalledApps.load() }.value
            }
            .confirmationDialog(
                pendingAppDeletion.map { "Delete context captured from \($0.name)?" } ?? "",
                isPresented: .isPresented(by: $pendingAppDeletion),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let app = pendingAppDeletion else { return }
                    Task { await screenContext.deleteObservations(since: nil, app: app.bundleID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deleted context can't be recovered. Your sessions and transcripts are not affected.")
            }
    }

    /// Excluded first, under a heading that says what the switch means.
    ///
    /// One alphabetical list of identical switches could not answer "am I
    /// protected?" — the twenty-six apps that were off sat scattered among two
    /// hundred that were on, and the switch alone never said which way was safe.
    private var appsPane: some View {
        let readable = filteredApps.filter { !exclusions.excludes($0) }
        return VStack(alignment: .leading, spacing: 10) {
            SearchField(prompt: "Search applications…", text: $appQuery)

            // The delete itself is server-side and nothing on screen shrinks, so
            // without this a per-app delete looks like it did nothing — same
            // reasoning as the sidebar's own `lastDeletion` line.
            if let outcome = screenContext.lastDeletion {
                Text(AmbientContextSidebarRow.deletionMessage(outcome))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
            }

            if excludedMatches.isEmpty, readable.isEmpty {
                SettingsCard {
                    SettingsRow(icon: "nc-window-pointer", title: emptyAppsTitle, subtitle: nil) { EmptyView() }
                }
            } else {
                appGroup("Never read", apps: excludedMatches)
                appGroup("Can be read", apps: readable.map { ExcludedApp(bundleID: $0.bundleID, name: $0.name) })
            }
        }
    }

    /// Built from the blocklist, not from the intersection with what happens to
    /// be installed. Most of the twenty-one apps excluded out of the box are
    /// messengers and password managers this Mac does not have — counting only
    /// the installed ones showed "26 never read" above a list of nine, which on
    /// a page about privacy reads as a bug rather than as protection.
    private var excludedMatches: [ExcludedApp] {
        exclusions.apps
            .filter { appQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(appQuery) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func appGroup(_ title: String, apps: [ExcludedApp]) -> some View {
        if !apps.isEmpty {
            SectionLabel("\(title) (\(apps.count))")
                .padding(.top, 4)
            SettingsCard {
                // Lazily rendered: the list is every app on the Mac, so an eager
                // stack builds hundreds of rows on every keystroke in the field.
                LazyVStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { SettingsRowDivider() }
                        appRow(app)
                    }
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

    private func appRow(_ app: ExcludedApp) -> some View {
        let installed = installedApps.first { $0.bundleID == app.bundleID }
        return HStack(spacing: 12) {
            if let icon = installed?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image("nc-window-pointer")
                    .icon(14)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.ink)
                // Kept in the list rather than hidden: an exclusion that is
                // already in place is the reassurance, and it starts working the
                // day the app is installed.
                if installed == nil {
                    Text("Not installed")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding(for: app))
                .nodSwitch()
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            // Independent of the switch above: excluding an app going forward
            // doesn't touch what it already captured, and this is the only way
            // to find and remove that — the delete menu in the sidebar only
            // scopes by time, not by app.
            Button("Delete Captured Context from \(app.name)…") { pendingAppDeletion = app }
        }
    }

    private func binding(for app: ExcludedApp) -> Binding<Bool> {
        Binding(
            get: { exclusions.excludesApp(bundleID: app.bundleID) },
            set: { excluded in
                if excluded {
                    exclusions.exclude(app)
                } else {
                    exclusions.removeApp(app.bundleID)
                }
            }
        )
    }
}
