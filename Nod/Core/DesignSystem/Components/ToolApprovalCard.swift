import SwiftUI

/// Asks before anything leaves Nod.
///
/// One card per model turn, not per call and not per product: a single
/// question routinely produces three searches, and three prompts in a row
/// teach the user to approve without reading — which is the failure mode this
/// exists to prevent. A second card raised where the first stood is that
/// failure at its worst, since the button under the cursor changes meaning
/// before the click lands.
///
/// So a round reaching two products is one card that names both, grouped by
/// product. Every call is listed, and nothing runs unless the whole card is
/// allowed.

struct ToolApprovalCard: View {
    let approval: ChatToolGate.Pending
    let onApprove: () -> Void
    /// Approve, and stop asking about reads from this product. Absent on a card
    /// carrying a write, or one reaching more than one product.
    var onApproveAlways: (() -> Void)?
    let onDeny: () -> Void

    private var batches: [ChatToolGate.Batch] {
        approval.round.batches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(batches, id: \.provider) { batch in
                    ProviderMark(provider: batch.provider, size: 14)
                }
                Text("Nod wants to use \(productList)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(batches, id: \.provider) { batch in
                    ForEach(Array(zip(batch.calls, batch.tools)), id: \.0.id) { call, tool in
                        requestRow(call: call, tool: tool)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Allow", action: onApprove)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .buttonStyle(.plain)

                if let provider = approval.alwaysAllowable, let onApproveAlways {
                    Button("Always allow \(provider.displayName)", action: onApproveAlways)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
                        .buttonStyle(.plain)
                }

                Button("Not now", action: onDeny)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    /// Every product the round reaches, so the header cannot describe less
    /// than the rows below it.
    private var productList: String {
        let names = batches.map(\.provider.displayName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Shows the arguments, not just the verb. "Search Linear" is not a decision
    /// the user can make; "search Linear for founders dashboard" is. The
    /// product's own mark rides along, since one card can carry two.
    private func requestRow(call: ChatToolCall, tool: ChatTool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(tool.mutating ? "nc-pen-writing" : "nc-magnifier")
                .icon(11)
                .foregroundStyle(tool.mutating ? Theme.Palette.warning : Theme.Palette.muted)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tool.verb) \(tool.provider.displayName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.8))
                Text(call.recognisableArgument(for: tool))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if tool.mutating {
                    ForEach(call.detailArguments(for: tool), id: \.name) { argument in
                        Text("\(argument.name): \(argument.value)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
