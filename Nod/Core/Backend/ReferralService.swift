import Foundation
import Supabase

/// Drives the Rewards screen and referral attribution (NOD-22).
///
/// The code is pure attribution — it tells the server which referrer to credit,
/// it is NOT a Paddle coupon. The friend's −50% comes from a single static
/// Paddle discount applied server-side in `create-checkout`; the referrer's free
/// month is granted by `paddle-webhook` after the friend's first payment. This
/// service only mints/returns the caller's stable code and reads back how many
/// friends have joined / been rewarded.
@MainActor
final class ReferralService: ObservableObject {
    @Published private(set) var code: String?
    @Published private(set) var joinedCount = 0
    @Published private(set) var claimableCount = 0
    @Published private(set) var rewardedCount = 0
    @Published private(set) var loadFailed = false

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// The shareable link a referrer hands to friends. The landing page reads
    /// `ref` and the deep link / paywall field carry it into checkout. Same host
    /// in both environments — it's the public marketing site.
    static func shareLink(for code: String) -> String {
        "https://hellonod.app/get-nod?ref=\(code)"
    }

    var shareLink: String? {
        code.map(Self.shareLink)
    }

    func refresh() async {
        loadFailed = false
        struct Row: Decodable { let status: String }
        do {
            // The code RPC and the status read are independent — run them
            // concurrently so the Rewards tab waits on the slower of the two,
            // not their sum.
            async let mintedTask: String = supabase
                .rpc("get_or_create_referral_code")
                .execute()
                .value
            async let rowsTask: [Row] = supabase
                .from("referrals")
                .select("status")
                .execute()
                .value

            let minted = try await mintedTask
            let rows = try await rowsTask
            code = minted
            joinedCount = rows.count
            claimableCount = rows.filter { $0.status == "earned" }.count
            rewardedCount = rows.filter { $0.status == "rewarded" }.count
            Log.ui.info("ReferralService.refresh code=\(minted) joined=\(joinedCount) claimable=\(claimableCount) rewarded=\(rewardedCount)")
        } catch {
            loadFailed = true
            Log.ui.error("ReferralService.refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pending code (attribution B)

    /// A code captured from a `nod://referral?code=…` deep link before the user
    /// reached the paywall. The paywall consumes it to pre-fill its field.
    private static let pendingKey = "referral.pendingCode"

    static func storePendingCode(_ code: String) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        UserDefaults.standard.set(normalized, forKey: pendingKey)
    }

    /// Returns and clears the pending code — single-use, so reopening the paywall
    /// later doesn't silently re-apply a stale referral.
    static func consumePendingCode() -> String? {
        let value = UserDefaults.standard.string(forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return value?.isEmpty == true ? nil : value
    }
}
