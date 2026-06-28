import SwiftUI

/// Connect Nod to an external AI client (Claude, ChatGPT, Gemini, …). Mints a
/// read-only, revocable personal access token shown ONCE, and lists/revokes
/// existing connections. The token + API are identical for every client; only
/// the per-provider setup snippet differs.
struct ConnectionsSection: View {
    @ObservedObject var service: ConnectionService

    @State private var client: ConnectionClient = .claude
    @State private var creating = false
    @State private var createError: String?
    /// The personal token from the most recent mint — embedded in the connector
    /// link, never shown on its own.
    @State private var newToken: String?
    @State private var linkCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "puzzlepiece.extension",
                    title: "Connect Nod to Claude",
                    subtitle: "Add Nod to Claude so it can read your meetings — only yours. Hit Connect, copy the link, and paste it into Claude’s connector settings. No API keys. Read-only and revocable any time."
                ) { EmptyView() }
            }

            newConnectionCard

            if let newToken {
                connectorLinkCard(newToken)
            }

            if !service.connections.isEmpty {
                Text("YOUR CONNECTIONS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.top, 4)

                SettingsCard {
                    ForEach(Array(service.connections.enumerated()), id: \.element.id) { index, conn in
                        if index > 0 { SettingsRowDivider() }
                        connectionRow(conn)
                    }
                }
            }
        }
        .task { await service.refresh() }
    }

    private var newConnectionCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                providerChip(.claude)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Claude connection")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("Creates a private link to paste into Claude.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(action: generate) {
                    Text(creating ? "Connecting…" : "Connect")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                        .opacity(creating ? 0.7 : 1)
                        .fixedSize()
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

    /// The provider's brand logo from the asset catalog, falling back to an SF
    /// Symbol until the logo is supplied. `size` is the square edge in points.
    @ViewBuilder
    private func providerIcon(_ client: ConnectionClient, size: CGFloat) -> some View {
        if let logo = NSImage(named: client.iconAssetName) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: client.fallbackSymbol)
                .font(.system(size: size * 0.64, weight: .medium))
                .frame(width: size, height: size)
        }
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

    /// The whole UX: one connector link to paste into the AI client. The personal
    /// token rides in the URL PATH (`…/mcp/<token>`) — there's no API-key field to
    /// fill, no OAuth, no terminal. Copy, paste, done. The token scopes the
    /// connector to this user's own meetings only.
    private func connectorLinkCard(_ token: String) -> some View {
        let link = SupabaseConfig.mcpBaseURL.appending(path: token).absoluteString
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                providerIcon(client, size: 16)
                Text("Add Nod to \(client.displayName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            Text(connectorSteps)
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

                Button(action: { copyLink(link) }) {
                    Text(linkCopied ? "Copied" : "Copy link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
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

    private var connectorSteps: String {
        switch client {
        case .claude:
            "In Claude (web or desktop): Settings → Connectors → Add custom connector → paste this link → Add. Then just ask Claude about your meetings."
        case .chatgpt:
            "In ChatGPT (web): Settings → Apps & Connectors → Advanced → turn on Developer mode → Create → paste this link → choose “No authentication” → Create. Then ask ChatGPT about your meetings."
        case .gemini:
            "Gemini's app doesn't support custom connectors yet, but the Gemini CLI does: run `gemini mcp add nod <paste this link> -t http`. Then ask Gemini about your meetings."
        case .other:
            "Paste this link wherever your AI app lets you add a connector / remote MCP server."
        }
    }

    private func copyLink(_ link: String) {
        NSPasteboard.copyText(link)
        linkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { linkCopied = false }
    }

    private func connectionRow(_ conn: Connection) -> some View {
        HStack(spacing: 12) {
            providerChip(conn.clientKind)
            VStack(alignment: .leading, spacing: 3) {
                Text(conn.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(subtitle(for: conn))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 12)
            Button(action: { newToken = nil; Task { await service.revoke(conn) } }) {
                Text("Revoke")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(Theme.Palette.danger.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func subtitle(for conn: Connection) -> String {
        var parts = [conn.clientKind.displayName]
        if let used = conn.lastUsedAt {
            parts.append("last used \(Self.relative.localizedString(for: used, relativeTo: Date()))")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func generate() {
        let selected = client
        creating = true
        createError = nil
        linkCopied = false
        Task {
            do {
                newToken = try await service.create(name: "\(selected.displayName) connection", client: selected)
            } catch {
                createError = "Couldn't create the connection. Please try again."
            }
            creating = false
        }
    }
}
