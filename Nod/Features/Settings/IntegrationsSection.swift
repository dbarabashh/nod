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

    private var authorized: [CatalogueApp] {
        catalogue.apps(for: service.linkedApps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            if let error = service.lastError {
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
            isPresented: isConfirmingDisconnect,
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

    /// Drives the dialog without a `Binding(get:set:)` in `body`: the identity of
    /// what is being disconnected and whether the sheet is up are one fact, and
    /// this keeps them from drifting apart.
    private var isConfirmingDisconnect: Binding<Bool> {
        Binding(
            get: { disconnecting != nil },
            set: { if !$0 { disconnecting = nil } }
        )
    }

    /// The tools Nod does not support, which is all of them but these.
    ///
    /// A call rather than a form. A typed tool name says which product somebody
    /// wants and nothing about the work they are trying to do with it — and the
    /// second half is what decides which adapter is worth writing. Twenty
    /// minutes with the person who would build it beats a hundred rows of
    /// product names.
    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Need an integration?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.75))
                Text("Book a call with Vlad. He builds them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 2)

            SettingsCard {
                SettingsRow(
                    icon: "nc-calendar",
                    title: "Book a call with Vlad",
                    subtitle: "Twenty minutes. Tell him which tool your team works in and what you'd want Nod to do in it."
                ) {
                    Button {
                        NSWorkspace.shared.open(Self.bookingURL)
                    } label: {
                        Text("Book a time")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.GlassButton.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .glassButtonSurface(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                }
            }
        }
    }

    /// The same booking link the site offers. Duplicated across repos rather
    /// than fetched: a settings row that needs a round trip before it can draw
    /// its own button is worse than a string two places have to agree on.
    private static let bookingURL = URL(string: "https://calendly.com/meet-vlad-from-nod/30min")!

    /// What actually happens, in the terms of the provider being dropped.
    private static func consequence(_ provider: IntegrationProvider) -> String {
        switch provider {
        case .linear:
            "Nod stops filing action items in Linear. Issues already filed stay where they are."
        case .googleCalendar:
            "Nod stops reading your calendar, and everything it has already read is deleted. Nothing in your calendar changes."
        case .slack:
            "Nod stops creating channels and adding people. Channels it already created stay, and everyone in them stays in them."
        case .github:
            "Nod stops reading your issues and pull requests. Nothing on GitHub changes — it never wrote anything."
        case .jira:
            "Nod stops filing action items in Jira. Issues already filed stay where they are."
        case .notion:
            "Nod stops reading your Notion pages. Nothing in Notion changes — it never wrote anything."
        case .asana:
            "Nod stops filing action items in Asana. Tasks already filed stay where they are."
        case .hubspot:
            "Nod stops reading your CRM. Nothing in HubSpot changes — it never wrote anything."
        case .gmail:
            "Nod stops reading your mail. Nothing is sent, deleted or marked read — it never could."
        case .googleDrive:
            "Nod stops finding your documents. Nothing in Drive changes — it only ever listed them."
        }
    }

    // MARK: - A product

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
        return HStack(spacing: 12) {
            providerChip(provider)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    ForEach(provider.capabilities.sorted { $0.rawValue < $1.rawValue }) { capability in
                        Text(capability.displayName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.Palette.surfaceStrong))
                    }
                }
                Text(isPending ? "Waiting for authorization in your browser…" : provider.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            connectControl(provider, isLinked: isLinked, isPending: isPending)
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

    /// Connected reads as a state, not a button — the thing you can do to a
    /// connection you already have is disconnect it, and that lives below with
    /// the rest of its settings rather than beside the name.
    @ViewBuilder
    private func connectControl(_ provider: IntegrationProvider, isLinked: Bool, isPending: Bool) -> some View {
        if isLinked {
            HStack(spacing: 5) {
                Image("nc-check")
                    .icon(10)
                Text("Connected")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.success)
            .accessibilityLabel("\(provider.displayName) connected")
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

    private func providerChip(_ provider: IntegrationProvider) -> some View {
        ProviderMark(provider: provider)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
    }
}
