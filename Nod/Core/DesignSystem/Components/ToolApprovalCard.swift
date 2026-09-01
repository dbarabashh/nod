import SwiftUI

/// Asks before anything leaves Nod.
///
/// One card per model turn, not per call: a single question routinely produces
/// three searches, and three prompts in a row teach the user to approve without
/// reading — which is the failure mode this exists to prevent. Every call is
/// still listed, and nothing runs unless the whole card is allowed.
struct ToolApprovalCard: View {
    let approval: ChatToolGate.Pending
    let onApprove: () -> Void
    /// Approve, and stop asking about reads from this product. Absent on a card
    /// carrying a write.
    var onApproveAlways: (() -> Void)?
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMark(provider: approval.provider, size: 14)
                Text("Nod wants to use \(approval.provider.displayName)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(zip(approval.calls, approval.tools)), id: \.0.id) { call, tool in
                    requestRow(call: call, tool: tool)
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

                if approval.mayAlwaysAllow, let onApproveAlways {
                    Button("Always allow \(approval.provider.displayName)", action: onApproveAlways)
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

    /// Shows the arguments, not just the verb. "Search Linear" is not a decision
    /// the user can make; "search Linear for founders dashboard" is.
    private func requestRow(call: ChatToolCall, tool: ChatTool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(tool.mutating ? "nc-pen-writing" : "nc-magnifier")
                .icon(11)
                .foregroundStyle(tool.mutating ? Theme.Palette.warning : Theme.Palette.muted)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.verb)
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
