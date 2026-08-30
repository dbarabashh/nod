import AppKit
import SwiftUI

struct ConnectionsSection: View {
    @ObservedObject var service: ConnectionService

    @State private var creating = false
    @State private var createError: String?
    @State private var newToken: String?
    @State private var linkCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "nc-puzzle-piece",
                    title: "Connect Nod to AI assistants",
                    subtitle: "Search your summaries and transcripts from ChatGPT or Claude. Official connections use secure OAuth and are read-only."
                ) {
                    Button("Setup guide") { open(Self.connectorsURL) }
                        .buttonStyle(.link)
                }
            }

            if service.rollout.officialConnectorsEnabled {
                officialConnectors
            } else {
                legacyCreationCard
            }

            if let newToken {
                legacyLinkCard(newToken)
            }

            if !service.connections.isEmpty {
                legacyConnections
            }
        }
        .task { await service.refresh() }
    }

    private var officialConnectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OFFICIAL CONNECTORS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)

            SettingsCard {
                officialConnectorRow(.chatgpt, url: service.rollout.chatGPTURL)
                SettingsRowDivider()
                officialConnectorRow(.claude, url: service.rollout.claudeURL)
            }
        }
    }

    private func officialConnectorRow(_ client: ConnectionClient, url: URL?) -> some View {
        HStack(spacing: 12) {
            providerChip(client)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("OAuth · meetings:read · read-only")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 12)
            if let url {
                Button("Install") { open(url) }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .buttonStyle(.plain)
            } else {
                Text("Coming soon")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var legacyCreationCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                providerChip(.claude)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom Claude connection")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("Temporary personal-token setup until the official connector launches.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(action: generate) {
                    Text(creating ? "Connecting…" : "Create legacy link")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                        .opacity(creating ? 0.7 : 1)
                }
                .buttonStyle(.plain)
                .disabled(creating)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let createError {
                SettingsRowDivider()
                Text(createError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private func legacyLinkCard(_ token: String) -> some View {
        let link = SupabaseConfig.mcpBaseURL.appending(path: token).absoluteString
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                providerIcon(.claude, size: 16)
                Text("Legacy Claude connector link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            Text("In Claude: Settings → Connectors → Add custom connector → paste this link → Add.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(link)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(linkCopied ? "Copied" : "Copy link") { copyLink(link) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .buttonStyle(.plain)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var legacyConnections: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LEGACY CONNECTIONS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.muted)
                Spacer()
                if let sunset = service.rollout.legacyPATSunsetAt {
                    Text("Sunset \(sunset.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.warning)
                }
            }

            SettingsCard {
                ForEach(Array(service.connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 { SettingsRowDivider() }
                    connectionRow(connection)
                }
            }
        }
    }

    private func connectionRow(_ connection: Connection) -> some View {
        HStack(spacing: 12) {
            providerChip(connection.clientKind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("Legacy")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.Palette.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Palette.warning.opacity(0.12), in: Capsule())
                }
                Text(subtitle(for: connection))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 12)
            Button("Revoke") {
                newToken = nil
                Task { await service.revoke(connection) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.Palette.danger)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).stroke(Theme.Palette.danger.opacity(0.5), lineWidth: 1))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func providerIcon(_ client: ConnectionClient, size: CGFloat) -> some View {
        Image(client.fallbackSymbol)
            .icon(size * 0.64)
            .frame(width: size, height: size)
    }

    private func providerChip(_ client: ConnectionClient) -> some View {
        providerIcon(client, size: 18)
            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
    }

    private func subtitle(for connection: Connection) -> String {
        var parts = [connection.clientKind.displayName]
        if let used = connection.lastUsedAt {
            parts.append("last used \(Self.relative.localizedString(for: used, relativeTo: Date()))")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " · ")
    }

    private func generate() {
        creating = true
        createError = nil
        linkCopied = false
        Task {
            do {
                newToken = try await service.create(name: "Claude connection", client: .claude)
            } catch {
                createError = "Couldn't create the connection. Please try again."
            }
            creating = false
        }
    }

    private func copyLink(_ link: String) {
        NSPasteboard.copyText(link)
        linkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { linkCopied = false }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private static let connectorsURL = URL(string: "https://hellonod.app/connectors")
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
