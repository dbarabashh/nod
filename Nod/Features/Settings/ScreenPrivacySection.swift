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
    @ObservedObject var screenContext: ScreenContextService
    /// Seeded from the file-backed flag, not `@AppStorage`: the durable value
    /// lives in `ScreenContextDefaults`, and binding the switch to the old
    /// UserDefaults key would show off whenever that key was dropped on exit.
    /// Bound to the service's published switch, not a local mirror — the
    /// sidebar offers the same toggle, and two mirrors of one file flag drift.
    private var ambientEnabled: Bool {
        screenContext.isAmbientEnabled
    }

    /// Gates the rows that only make sense while capture can actually run — the
    /// Accessibility prompt in particular, since asking an unentitled account
    /// for a permission it cannot use is a dead end.
    ///
    /// Retention deliberately does NOT use this. The RLS gate leaves SELECT and
    /// DELETE open so a downgraded user can still manage what Nod already
    /// stored, and hiding the picker would leave those rows under a ceiling only
    /// we could change.
    private var ambientRunnable: Bool {
        screenContext.isEntitled && screenContext.isAmbientEnabled
    }

    @AppStorage(ScreenContextDefaults.retentionDaysKey) private var retentionDays = ScreenContextDefaults.defaultRetentionDays
    @State private var scope: Scope = .apps
    @State private var installedApps: [InstalledApp] = []
    @State private var appQuery = ""
    @State private var websiteDraft = ""
    @State private var alwaysIncludeDraft = ""
    @State private var alwaysIncludeError: String?
    @State private var showsCategories = true
    /// Set by the app row's "Delete captured context" command, confirmed
    /// before it runs — deletion can't be undone, same rule as the sidebar's
    /// own delete menu (`AmbientContextSidebarRow`).
    @State private var pendingAppDeletion: InstalledApp?

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
                icon: "nc-sparkle-3",
                title: "Ambient context",
                subtitle: "Let Nod read the window you're working in, so you can ask about what you were doing — "
                    + "not just what was said. Off by default. Excluded apps and sites are never read."
            ) {
                // Off the plan the switch would flip, persist, and capture
                // nothing — RLS refuses the writes — so it is replaced by the
                // one control that changes the answer.
                if screenContext.isEntitled {
                    Toggle("", isOn: Binding(
                        get: { screenContext.isAmbientEnabled },
                        set: { screenContext.setAmbientEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(Theme.Palette.violet)
                    .labelsHidden()
                    .controlSize(.small)
                } else {
                    Button("Upgrade to Pro") {
                        NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                    }
                }
            }

            if ambientRunnable, screenContext.needsAccessibility {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-triangle-warning",
                    title: "Accessibility access needed",
                    subtitle: "macOS has to allow Nod to read window text before ambient context can run. "
                        + "Grant it in System Settings, then switch this back on."
                ) {
                    Button("Open Settings") { AccessibilityAccess.openSystemSettings() }
                }
            }

            // Without this the switch reads "on" through a pause, and nothing on
            // this pane says capture is suspended — the state the sidebar shows
            // and the state Settings shows would disagree.
            if case let .paused(until) = screenContext.activityState {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-media-pause",
                    title: "Paused \(ScreenContextService.ActivityState.remaining(until: until))",
                    subtitle: "Nothing is being read. Capture resumes on its own when the pause runs out."
                ) {
                    Button("Resume now") { screenContext.resume() }
                }
            }

            if ambientEnabled {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-refresh-2",
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

            // The delete itself is server-side and nothing on screen shrinks,
            // so without this a per-app delete looks like it did nothing —
            // same reasoning as the sidebar's own `lastDeletion` line.
            if let outcome = screenContext.lastDeletion {
                Text(AmbientContextSidebarRow.deletionMessage(outcome))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
            }

            SettingsCard {
                // Filtered once per pass, not once per reference — and lazily
                // rendered: the list is every app on the Mac, so an eager stack
                // builds hundreds of rows on every keystroke in the field.
                let apps = filteredApps
                if apps.isEmpty {
                    SettingsRow(icon: "nc-window-pointer", title: emptyAppsTitle, subtitle: nil) { EmptyView() }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
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
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            }
            Text(app.name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 12)
            Toggle("", isOn: binding(for: app))
                .toggleStyle(.switch)
                .tint(Theme.Palette.violet)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            // Independent of the switch above: excluding an app going forward
            // doesn't touch what it already captured, and this is the only
            // way to find and remove that — the delete menu in the sidebar
            // only scopes by time, not by app.
            Button("Delete Captured Context from \(app.name)…") { pendingAppDeletion = app }
        }
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
            Image(category.icon)
                .icon(14)
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
                .tint(Theme.Palette.violet)
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
            siteList(
                SiteListStyle(
                    title: "Specific sites (\(exclusions.websites.count))",
                    icon: "nc-earth",
                    empty: "No sites added",
                    placeholder: "bank.com",
                    marksDefaults: true
                ),
                sites: exclusions.websites,
                draft: $websiteDraft,
                add: addWebsite,
                remove: exclusions.removeWebsite
            )

            // Matching is on the browser window title, so a tab that never names
            // the site slips through. Say so rather than imply a guarantee.
            Text("Sites are matched by window title. To be certain, exclude the browser itself.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            alwaysIncludedSites
        }
    }

    /// The escape hatch for the category switches. Categories match keywords in
    /// a window title, so they are broad by construction and will catch a site
    /// the user actually wants read — a supplier portal under "shopping", a
    /// recruiting call under "social". Without this the only way out is to give
    /// up the whole category.
    private var alwaysIncludedSites: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Captured even when an excluded category matches them. A site you excluded by name stays excluded.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            siteList(
                SiteListStyle(
                    title: "Always include (\(exclusions.alwaysIncluded.count))",
                    icon: "nc-check",
                    empty: "Nothing always included",
                    placeholder: "portal.supplier.com"
                ),
                sites: exclusions.alwaysIncluded,
                draft: $alwaysIncludeDraft,
                add: addAlwaysIncluded,
                remove: exclusions.removeAlwaysIncluded
            )

            // A rejection has to say why. Fifteen sites ship on the blocklist,
            // so typing one of them here is an easy thing to do and used to
            // produce nothing at all — a filled field, no row, no explanation.
            if let alwaysIncludeError {
                Text(alwaysIncludeError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A titled list of domains with a remove button and an add field. The two
    /// site lists differ only in their strings and their two verbs, and each
    /// re-spelling the row, the empty state and the trim-and-disable rule is how
    /// they drift — a change made to one and not the other is invisible in the
    /// list nobody opens.
    /// The strings that tell the two lists apart. A struct rather than six more
    /// arguments — the shape is the point, and it keeps the signature readable.
    private struct SiteListStyle {
        let title: String
        let icon: String
        let empty: String
        let placeholder: String
        /// Whether a shipped default gets a "Excluded by default" line. Only the
        /// blocklist ships any.
        var marksDefaults = false
    }

    @ViewBuilder
    private func siteList(
        _ style: SiteListStyle,
        sites: [String],
        draft: Binding<String>,
        add: @escaping () -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Text(style.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)

        SettingsCard {
            if sites.isEmpty {
                SettingsRow(icon: style.icon, title: style.empty, subtitle: nil) { EmptyView() }
            } else {
                ForEach(Array(sites.enumerated()), id: \.element) { index, site in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(icon: style.icon, title: site, subtitle: subtitle(for: site, style: style)) {
                        Button { remove(site) } label: {
                            Image("nc-minus")
                                .icon(13)
                                .foregroundStyle(Theme.Palette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        HStack(spacing: 8) {
            TextField(style.placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// A shipped default says so, because a list the user never typed is
    /// otherwise indistinguishable from one they did — and the whole defence of
    /// shipping defaults is that they are visible and removable.
    private func subtitle(for site: String, style: SiteListStyle) -> String? {
        guard style.marksDefaults, ScreenExclusions.isDefaultWebsite(site) else { return nil }
        return "Excluded by default"
    }

    private func addWebsite() {
        guard exclusions.excludeWebsite(websiteDraft) else { return }
        websiteDraft = ""
    }

    private func addAlwaysIncluded() {
        guard let rejection = exclusions.alwaysInclude(alwaysIncludeDraft) else {
            alwaysIncludeError = nil
            alwaysIncludeDraft = ""
            return
        }
        let site = ScreenExclusions.normalizeWebsite(alwaysIncludeDraft)
        alwaysIncludeError = switch rejection {
        case .empty: "Enter a domain, like portal.supplier.com."
        case .duplicate: "“\(site)” is already always included."
        case .excluded:
            "“\(site)” is on the excluded list above, and an exclusion always wins. Remove it there first."
        }
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "preview") ?? .standard
    let exclusions = ScreenExclusions(defaults: defaults)
    return ScreenPrivacySection(
        exclusions: exclusions,
        screenContext: ScreenContextService(supabase: nil, exclusions: exclusions)
    )
    .padding()
    .frame(width: 460)
}
