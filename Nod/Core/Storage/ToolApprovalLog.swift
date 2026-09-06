import Foundation
import Supabase

/// Writes each answered tool card into `tool_approvals`, where today the
/// decision evaporates the moment it is made.
///
/// This is the one stream the observation ledger adds: everything else it
/// counts already lands in a table. Names only — the provider and the action
/// names that were on the card — never parameters, because the ledger counts
/// habits and a habit is a shape, not its contents.
///
/// Best-effort by design: a miss costs the miner one data point, and a chat
/// turn must never wait on, or fail over, bookkeeping.
@MainActor
final class ToolApprovalLog {
    private let supabase: SupabaseClient
    private let auth: AuthService

    init(supabase: SupabaseClient, auth: AuthService) {
        self.supabase = supabase
        self.auth = auth
    }

    /// `unasked` marks reads that ran because the person set "allow reads" —
    /// recorded, but excluded from mining, or a standing preference would count
    /// as a hundred enthusiastic approvals.
    func record(
        provider: IntegrationProvider,
        tools: [ChatTool],
        allowed: Bool,
        unasked: Bool
    ) {
        // The table's insert policy checks `user_id` against the caller, and
        // nothing fills the column in: a row without it is refused, and this
        // log stayed empty from the day it shipped.
        guard let userID = auth.session?.user.id else { return }
        struct Row: Encodable {
            let userID: UUID
            let provider: String
            let actions: [String]
            let mutating: Bool
            let allowed: Bool
            let unasked: Bool

            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case provider, actions, mutating, allowed, unasked
            }
        }
        let row = Row(
            userID: userID,
            provider: provider.rawValue,
            actions: tools.map(\.action),
            mutating: tools.contains { $0.mutating },
            allowed: allowed,
            unasked: unasked
        )
        Task { [supabase] in
            do {
                try await supabase.from("tool_approvals").insert(row).execute()
            } catch {
                Log.ui.debug("tool approval log skipped: \(error.localizedDescription)")
            }
        }
    }
}
