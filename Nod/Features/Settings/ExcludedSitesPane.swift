import SwiftUI

/// Sites Nod must not read, by category and by name, plus the escape hatch.
struct ExcludedSitesPane: View {
    @ObservedObject var exclusions: ScreenExclusions

    @State private var websiteDraft = ""
    @State private var alwaysIncludeDraft = ""
    @State private var alwaysIncludeError: String?
    @State private var showsCategories = true

    var body: some View {
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
                .nodSwitch()
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

            // A rejection has to say why. Fifteen sites ship on the blocklist, so
            // typing one of them here is an easy thing to do and used to produce
            // nothing at all — a filled field, no row, no explanation.
            if let alwaysIncludeError {
                Text(alwaysIncludeError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The strings that tell the two site lists apart. A struct rather than six
    /// more arguments — the shape is the point, and it keeps the signature
    /// readable.
    private struct SiteListStyle {
        let title: String
        let icon: String
        let empty: String
        let placeholder: String
        /// Whether a shipped default gets an "Excluded by default" line. Only
        /// the blocklist ships any.
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
