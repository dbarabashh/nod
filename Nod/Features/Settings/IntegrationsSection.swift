import SwiftUI

struct IntegrationsSection: View {
    @ObservedObject var service: IntegrationService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "nc-link",
                    title: "Let Nod act in your tools",
                    subtitle: "Connecting opens the provider's own authorization page. Nod never sees your password, and you can revoke access from the provider at any time."
                ) {
                    EmptyView()
                }
            }

            SettingsCard {
                ForEach(Array(IntegrationProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { SettingsRowDivider() }
                    row(provider)
                }
            }

            if let error = service.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.danger)
            }
        }
        .task { await service.refresh() }
        .onDisappear { service.cancelPending() }
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
            HStack(spacing: 5) {
                Image("nc-check")
                    .icon(10)
                Text("Connected")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.success)
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
