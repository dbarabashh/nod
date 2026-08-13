import AppKit
import SwiftUI

/// Files an action item into a connected tracker, in one click.
///
/// Draws one mark per connected tracker and files into the one that is clicked.
/// Nothing connected means nothing drawn — a button offering an integration the
/// user hasn't set up is an advert, not an affordance — and no confirmation is
/// asked, because clicking this item *is* the decision, unlike the chat, where a
/// model made it.
///
/// Once filed the button is replaced by the reference, which is also what stops
/// the same item being filed twice.
struct ActionItemFilingButton: View {
    let item: ActionItem

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @State private var filing: IntegrationProvider?
    /// Local, not the service's `lastError`: that one is rendered in Settings,
    /// and a row on Home failing to file has no way to show it there.
    @State private var failed = false

    var body: some View {
        if let filed = item.filed {
            reference(filed)
        } else if let filing {
            ProgressView()
                .controlSize(.small)
                .help("Filing in \(filing.displayName)…")
        } else {
            HStack(spacing: 4) {
                ForEach(integrations.taskTargets) { provider in
                    mark(provider)
                }
            }
        }
    }

    private func mark(_ provider: IntegrationProvider) -> some View {
        Button { file(in: provider) } label: {
            Image(provider.iconName)
                .icon(11)
                .foregroundStyle(failed ? Theme.Palette.danger : Theme.Palette.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help(failed ? "Couldn't file that — try again" : "File in \(provider.displayName)")
    }

    private func reference(_ filed: ProviderLinkItem) -> some View {
        Button { NSWorkspace.shared.open(filed.url) } label: {
            HStack(spacing: 4) {
                Image(filed.provider.iconName)
                    .icon(10)
                Text(filed.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open \(filed.title) in \(filed.provider.displayName)")
    }

    private func file(in provider: IntegrationProvider) {
        filing = provider
        failed = false
        Task {
            if let filed = await integrations.file(item, in: provider) {
                await actionItemStore.recordFiling(itemID: item.id, reference: filed)
            } else {
                failed = true
            }
            filing = nil
        }
    }
}
