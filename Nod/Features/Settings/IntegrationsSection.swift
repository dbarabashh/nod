import AppKit
import SwiftUI

/// Every product Nod can reach, as one list.
///
/// This was two cards — "let Nod act in your tools" and "let Nod read from
/// your tools" — which is a true statement about the architecture and the wrong
/// question for somebody looking for Slack. People arrive knowing the product's
/// name, so the name is what the list is keyed on, with the kind of tool it is
/// beside it and the search field above.
///
/// A row says three things: which product, what it is for, and whether it is
/// connected. Everything else — which team it serves, importing members,
/// disconnecting — lives inside the row, because those are settings for a
/// connection you already made and they were what made this page unreadable:
/// four controls in a line. What the *organization* permits left this page
/// entirely: it is one question an administrator answers about every product,
/// and it is asked once, in the Tools table on the Organization page.
struct IntegrationsSection: View {
    @ObservedObject var service: IntegrationService
    /// Every other product the broker can authorize.
    @ObservedObject var catalogue: IntegrationCatalogue
    /// Optional: teams only exist for someone in an organization, and the picker
    /// stays out of the way entirely for everyone else.
    var organizations: OrganizationService?
    /// Absent in previews. Without it nothing is hidden — the server refuses a
    /// connection the plan doesn't carry either way, and a page that greys out
    /// rows because it failed to load an entitlement is worse than one that lets
    /// somebody press a button and read why.
    var entitlements: EntitlementService?
    /// Absent in previews, and then so is the credit counter.
    var billing: BillingService?

    /// Which provider the user has asked to disconnect, while they confirm it.
    @State private var disconnecting: IntegrationProvider?
    @State private var expanded: IntegrationProvider?
    @State private var search = ""

    private var matches: [IntegrationProvider] {
        let all = IntegrationProvider.allCases
        guard !search.isEmpty else { return all }
        return all.filter { provider in
            provider.displayName.localizedCaseInsensitiveContains(search)
                || provider.summary.localizedCaseInsensitiveContains(search)
                || provider.capabilities.contains { $0.displayName.localizedCaseInsensitiveContains(search) }
        }
    }

    /// A connection this plan cannot reach. Only ever true once an entitlement
    /// has actually loaded and says so — never while it is unknown.
    private func isBeyondPlan(_ provider: IntegrationProvider) -> Bool {
        guard let entitlement = entitlements?.entitlement else { return false }
        return !entitlement.can(provider.requiredFeature)
    }

    private var authorized: [CatalogueApp] {
        catalogue.apps(for: service.linkedApps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let entitlements, let billing {
                EntitlementCreditsCard(entitlements: entitlements, billing: billing, organizations: organizations)
            }
            SettingsCard {
                SettingsRow(
                    icon: "nc-link",
                    title: "Connect your tools",
                    subtitle: "Connecting opens the provider's own authorization page. Nod never sees your password, and you can revoke access from the provider at any time."
                ) {
                    EmptyView()
                }
            }

            SearchField(prompt: "Search tools", text: $search)

            SettingsCard {
                if matches.isEmpty, authorized.isEmpty {
                    SettingsEmptyRow("Nothing matches “\(search)”")
                } else {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { SettingsRowDivider() }
                        providerRow(provider)
                    }
                    ForEach(Array(authorized.enumerated()), id: \.element.id) { index, app in
                        if index > 0 || !matches.isEmpty { SettingsRowDivider() }
                        CatalogueRow(app: app)
                    }
                }
            }

            requestSection

            if let error = service.lastError ?? billing?.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.danger)
            }
        }
        .task {
            await service.refresh()
            await catalogue.resolve(service.linkedApps)
        }
        .onChange(of: service.linkedApps) { slugs in
            Task { await catalogue.resolve(slugs) }
        }
        .onDisappear {
            service.cancelPending()
            catalogue.forgetMarks()
        }
        .confirmationDialog(
            "Disconnect \(disconnecting?.displayName ?? "")?",
            isPresented: .isPresented(by: $disconnecting),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                guard let provider = disconnecting else { return }
                Task { _ = await service.disconnect(provider) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(disconnecting.map(Self.consequence) ?? "")
        }
    }

    /// The tools Nod does not support, which is all of them but these.
    ///
    /// A written ask rather than a form. A typed tool name says which product
    /// somebody wants and nothing about the work they are trying to do with it —
    /// and the second half is what decides which adapter is worth writing. The
    /// subject line is filled in so the reply lands in one thread; the body is
    /// left empty, because a prompt somebody has to delete before they can type
    /// is worse than a blank message.
    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Need an integration?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.75))
                Text("Write to us. We build them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 2)

            // Brand-tinted rather than a standard card: this is the one row on
            // the page that is an invitation and not a setting, and the featured
            // chip in chat and the live capture ring already say "brand" this
            // way — a wash of `brand` behind, `brand` on the glyph.
            SettingsRow(
                title: "Ask for an integration",
                subtitle: "Tell us which tool your team works in and what you'd want Nod to do in it.",
                subtitleTone: .secondary,
                leading: {
                    Image("nc-paper-plane-2")
                        .icon(14)
                        .foregroundStyle(Theme.Palette.brand)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .fill(Theme.Palette.brand.opacity(0.16))
                        )
                },
                trailing: {
                    GlassPillButton("Send an email", size: .compact, tint: .brand) {
                        if let url = Self.requestURL { NSWorkspace.shared.open(url) }
                    }
                    .linkCursor()
                    .help("Opens your mail app to dmytro@hellonod.app")
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                    .fill(Theme.Palette.brand.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                            .stroke(Theme.Palette.brand.opacity(0.35), lineWidth: 0.5)
                    )
            )
        }
    }

    /// Optional rather than force-unwrapped: the button simply does nothing if a
    /// future edit breaks the string, which is better than a crash in Settings.
    private static let requestURL = URL(
        string: "mailto:dmytro@hellonod.app?subject=Nod%20integration%20request"
    )

    /// What actually happens, in the terms of the provider being dropped.
    private static func consequence(_ provider: IntegrationProvider) -> String {
        switch provider {
        case .linear:
            "Nod stops filing action items in Linear. Issues already filed stay where they are."
        case .googleCalendar:
            "Nod stops reading and acting in your calendar, and everything it has already read is deleted. Events it created or changed stay as they are."
        case .slack:
            "Nod stops creating channels and adding people. Channels it already created stay, and everyone in them stays in them."
        case .github:
            "Nod stops reading and filing issues. Issues and comments already filed stay where they are."
        case .jira:
            "Nod stops filing action items in Jira. Issues already filed stay where they are."
        case .notion:
            "Nod stops reading and writing pages. Pages it already created stay where they are."
        case .asana:
            "Nod stops filing action items in Asana. Tasks already filed stay where they are."
        case .hubspot:
            "Nod stops reading your CRM and logging notes. Notes already logged stay on their records."
        case .gmail:
            "Nod stops reading your mail and saving drafts. Drafts already saved stay in Gmail, unsent."
        case .googleDrive:
            "Nod stops finding and reading your documents. Nothing in Drive changes — it never wrote anything."
        case .googleAds:
            "Nod stops reading your campaigns. Nothing in Google Ads changes — it never spent anything."
        case .googleTasks:
            "Nod stops filing action items in Google Tasks. Tasks already filed stay where they are."
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: IntegrationProvider) -> some View {
        let isLinked = service.linked.contains(provider)
        let isOpen = expanded == provider
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(provider, isLinked: isLinked, isOpen: isOpen)
            if isOpen {
                details(provider, isLinked: isLinked)
            }
        }
    }

    private func summaryRow(_ provider: IntegrationProvider, isLinked: Bool, isOpen: Bool) -> some View {
        let isPending = service.pending == provider
        let isBlocked = service.blockedByOrganization.contains(provider)
        return HStack(spacing: 12) {
            ProviderMark(provider: provider, tiled: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    ForEach(provider.capabilities.sorted { $0.rawValue < $1.rawValue }) { capability in
                        TagPill(capability.displayName)
                    }
                }
                Text(summaryLine(provider, isPending: isPending, isBlocked: isBlocked))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            connectControl(
                provider,
                isLinked: isLinked,
                isPending: isPending,
                isBlocked: isBlocked,
                isBeyondPlan: isBeyondPlan(provider)
            )
            Image(isOpen ? "nc-chevron-down" : "nc-chevron-right")
                .icon(9)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            expanded = expanded == provider ? nil : provider
        }
        .linkCursor()
        .accessibilityElement(children: .combine)
        .accessibilityHint(isOpen ? "Hides this tool's settings" : "Shows this tool's settings")
    }

    /// What the row says about a tool nobody in the company may use.
    ///
    /// Not `provider.summary`: that describes what Nod would do with the tool,
    /// which is exactly what it is not doing. The person's own next move is in
    /// somebody else's settings, so the line has to say whose.
    private func summaryLine(_ provider: IntegrationProvider, isPending: Bool, isBlocked: Bool) -> String {
        if isPending { return "Waiting for authorization in your browser…" }
        if isBlocked { return "Your organization has turned this off. An owner can allow it again in Organization settings." }
        return provider.summary
    }

    /// Connected reads as a state, not a button — the thing you can do to a
    /// connection you already have is disconnect it, and that lives below with
    /// the rest of its settings rather than beside the name.
    ///
    /// Turned off outranks both, connected or not. A green tick over a
    /// forbidden tool would promise something the chat refuses, and a Connect
    /// button on one leads through an authorization that changes nothing.
    @ViewBuilder
    private func connectControl(
        _ provider: IntegrationProvider,
        isLinked: Bool,
        isPending: Bool,
        isBlocked: Bool,
        isBeyondPlan: Bool
    ) -> some View {
        if isBlocked {
            StatusLabel(icon: "nc-lock", title: "Turned off", tint: Theme.Palette.warning)
                .accessibilityLabel("\(provider.displayName) turned off for your organization")
        } else if isLinked {
            StatusLabel(icon: "nc-check", title: "Connected", tint: Theme.Palette.success)
                .accessibilityLabel("\(provider.displayName) connected")
        } else if isBeyondPlan {
            // Named rather than greyed out: somebody looking at Jira on Starter
            // is being told what to buy, not that the row is broken.
            StatusLabel(icon: "nc-lock", title: "On Pro", tint: Theme.Palette.muted)
                .accessibilityLabel("\(provider.displayName) is available on Pro")
        } else if isPending {
            Button("Cancel") { service.cancelPending() }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
                .buttonStyle(.plain)
        } else {
            Button {
                Task { await service.connect(provider) }
            } label: {
                Text("Connect")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func details(_ provider: IntegrationProvider, isLinked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(provider.whatNodDoes, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image("nc-check")
                            .icon(9)
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.top, 3)
                        Text(line)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if isLinked {
                connectedSettings(provider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    /// Settings that only mean anything once the account is linked.
    private func connectedSettings(_ provider: IntegrationProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowDivider()
            HStack(spacing: 12) {
                teamPicker(provider)
                directorySync(provider)
                Spacer(minLength: 8)
                Button { disconnecting = provider } label: {
                    Text("Disconnect")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.danger)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }

    /// Re-reads this workspace's member list into the organization.
    ///
    /// Connecting already did it once — that is what makes a company usable
    /// without inviting everyone to Nod first. This is for afterwards: somebody
    /// joined the workspace, or the tool was connected before the organization
    /// existed. Administrators only, because filling a company's directory is an
    /// administrative act and a member's own workspace is not the company.
    @ViewBuilder
    private func directorySync(_ provider: IntegrationProvider) -> some View {
        if provider.isDirectorySource,
           let organizations,
           let membership = organizations.activeMembership,
           membership.role.administers {
            Button {
                Task {
                    if await service.syncDirectory(provider) != nil {
                        await organizations.refreshPeople()
                    }
                }
            } label: {
                // The label carries the text in both states. Swapping the icon
                // for a bare `ProgressView` left the button nameless to
                // VoiceOver at exactly the moment it was doing something.
                Label {
                    Text("Import \(provider.displayName) members")
                } icon: {
                    if service.isSyncingDirectory == provider {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Image("nc-refresh-2")
                            .icon(12)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .linkCursor()
            .disabled(service.isSyncingDirectory != nil)
            .help("Import who is in this workspace, so meetings can assign work to them")
        }
    }

    /// Which team this connection serves. Absent unless the person is actually in
    /// one — a picker with nothing to pick is a question with no answer — and
    /// absent for anything read-only: a calendar is one person's, so asking which
    /// team it belongs to would imply a sharing that does not happen.
    @ViewBuilder
    private func teamPicker(_ provider: IntegrationProvider) -> some View {
        if provider.role == .actsIn, let organizations, let orgID = organizations.activeOrgID {
            let teams = organizations.teams(in: orgID)
            if !teams.isEmpty {
                let current = organizations.teams.first { $0.id == service.teamByProvider[provider] }
                Menu {
                    Button("No team") {
                        Task { await service.setTeam(nil, for: provider) }
                    }
                    Divider()
                    ForEach(teams) { team in
                        Button(team.name) {
                            Task { await service.setTeam(team.id, for: provider) }
                        }
                    }
                } label: {
                    Text(current?.name ?? "No team")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .plainMenuChrome()
                .fixedSize()
                .accessibilityLabel("Team for \(provider.displayName)")
            }
        }
    }
}
