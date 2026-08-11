import SwiftUI

/// Referral rewards (NOD-22). Shows the user's stable code + share link, how many
/// friends subscribed, and any free months waiting to be claimed. The friend gets
/// −50% off their first month (monthly billing); the user earns a free month on
/// their own plan once a friend stays past their first renewal — claimable while
/// the user is a paying subscriber.
struct RewardsSection: View {
    @ObservedObject var service: ReferralService
    @ObservedObject var entitlements: EntitlementService
    /// Optional so the section still previews without the composition root.
    var analytics: ProductAnalytics?
    @State private var linkCopied = false

    /// Whether the entitlement has loaded yet. Until it has we don't know if the
    /// user is paying, so we must not nudge an actual subscriber to "subscribe".
    private var entitlementKnown: Bool {
        entitlements.entitlement != nil
    }

    /// Earned months are only paid onto a live 'active' subscription (matches the
    /// server claim gate). Trial / none → the months wait until the user
    /// subscribes (the conversion nudge).
    private var canClaim: Bool {
        entitlements.entitlement?.status == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "nc-gift",
                    title: "Give −50%, get a free month",
                    subtitle: "Share your link. Friends get 50% off their first month of Nod (monthly billing). You earn a free month on your plan once a friend stays past their first renewal — up to 6 free months a year."
                ) { EmptyView() }
            }

            if let link = service.shareLink, let code = service.code {
                if service.claimableCount > 0 { claimableBanner }
                shareCard(code: code, link: link)
                statusRow
            } else if service.loadFailed {
                errorCard
            } else {
                loadingCard
            }
        }
        .task {
            await service.refresh()
            await entitlements.refresh()
        }
    }

    private var claimableBanner: some View {
        let n = service.claimableCount
        let months = "\(n) free month\(n == 1 ? "" : "s")"
        // Only nudge to subscribe once we KNOW the user isn't already paying —
        // otherwise a subscriber whose entitlement hasn't loaded sees a wrong CTA.
        let showSubscribeCTA = entitlementKnown && !canClaim
        return SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(
                    icon: "nc-hourglass",
                    title: canClaim ? "\(months) on the way" : "\(months) waiting",
                    subtitle: canClaim
                        ? "Your earned months are applied to your plan automatically as it renews."
                        : "Subscribe to a paid plan to start claiming your earned free months — they're held until then."
                ) { EmptyView() }

                if showSubscribeCTA {
                    Button { NotificationCenter.default.post(name: .nodOpenSubscription, object: nil) } label: {
                        Text("Subscribe to claim")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.GlassButton.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .glassButtonSurface(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func shareCard(code: String, link: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Your referral code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(code)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(Theme.Palette.surfaceStrong)
                    )
            }
            Text("Send friends this link and code — they apply it on the upgrade screen.")
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

    private var statusRow: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "\(service.joinedCount) friend\(service.joinedCount == 1 ? "" : "s") subscribed",
                subtitle: "\(service.rewardedCount) free month\(service.rewardedCount == 1 ? "" : "s") received so far."
            ) { EmptyView() }
        }
    }

    private var loadingCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your referral link…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var errorCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                Text("Couldn't load your referral link.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 12)
                Button("Retry") { Task { await service.refresh() } }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func copyLink(_ link: String) {
        NSPasteboard.copyText(link)
        // The referral funnel starts here, so it is the one place worth counting.
        analytics?.record(
            .referralLinkShared,
            properties: .init(entryPoint: .settings, surface: .settings, outcome: .success)
        )
        linkCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            linkCopied = false
        }
    }
}
