import SwiftUI

struct IntegrationsSection: View {
    @ObservedObject var service: IntegrationService
    /// Optional: teams only exist for someone in an organization, and the picker
    /// stays out of the way entirely for everyone else.
    var organizations: OrganizationService?

    /// Which provider the user has asked to disconnect, while they confirm it.
    @State private var disconnecting: IntegrationProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            group(
                .actsIn,
                icon: "nc-link",
                title: "Let Nod act in your tools",
                subtitle: "Connecting opens the provider's own authorization page. Nod never sees your password, and you can revoke access from the provider at any time."
            )

            group(
                .readsFrom,
                icon: "nc-calendar",
                title: "Let Nod read from your tools",
                subtitle: "Read-only, and only what the provider's own consent screen lists. Nod never writes to these."
            )

            if let error = service.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.danger)
            }
        }
        .task { await service.refresh() }
        .onDisappear { service.cancelPending() }
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

    /// What actually happens, in the terms of the provider being dropped.
    private static func consequence(_ provider: IntegrationProvider) -> String {
        switch provider {
        case .linear:
            "Nod stops filing action items in Linear. Issues already filed stay where they are."
        case .googleCalendar:
            "Nod stops reading your calendar, and everything it has already read is deleted. Nothing in your calendar changes."
        }
    }

    private func group(
        _ role: IntegrationRole,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                    EmptyView()
                }
            }
            SettingsCard {
                ForEach(Array(IntegrationProvider.all(role).enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { SettingsRowDivider() }
                    row(provider)
                }
            }
        }
    }

    private func row(_ provider: IntegrationProvider) -> some View {
        let isLinked = service.linked.contains(provider)
        let isPending = service.pending == provider

        return HStack(spacing: 12) {
            providerChip(provider)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(isPending ? "Waiting for authorization in your browser…" : provider.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing(provider, isLinked: isLinked, isPending: isPending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func trailing(_ provider: IntegrationProvider, isLinked: Bool, isPending: Bool) -> some View {
        if isLinked {
            HStack(spacing: 12) {
                teamPicker(provider)
                HStack(spacing: 5) {
                    Image("nc-check")
                        .icon(10)
                    Text("Connected")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Theme.Palette.success)
                .accessibilityLabel("\(provider.displayName) connected")

                Button { disconnecting = provider } label: {
                    Text("Disconnect")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.Palette.surfaceStrong)
                        )
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
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
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
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
        Image(provider.iconName)
            .icon(12)
            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
    }
}
