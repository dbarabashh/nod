import Combine
import Foundation
import Sparkle
import Supabase

/// The Sparkle channel this account may see updates from, cached on disk.
///
/// Sparkle asks its delegate for the allowed channels *synchronously*, inside
/// the update check, so the answer has to already be on disk when the check
/// runs — a live read would be too late. `ReleaseChannelStore` refreshes the
/// cache at launch; this is the value Sparkle actually reads.
enum ReleaseChannel {
    static let defaultsKey = "update.channel"

    static var cached: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }
}

/// Sparkle's view of that cache. An empty set is Sparkle's default and means
/// "untagged items only" — what every account that was never enrolled gets.
final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard let channel = ReleaseChannel.cached, !channel.isEmpty else { return [] }
        return [channel]
    }
}

/// Keeps `ReleaseChannel.cached` in step with `release_channel_members`.
/// Read-only from the client: enrolment is service-role only, so there is
/// nothing here to write.
@MainActor
final class ReleaseChannelStore: ObservableObject {
    @Published private(set) var channel: String?

    private let supabase: SupabaseClient
    private let auth: AuthService
    private static let tableName = "release_channel_members"

    init(supabase: SupabaseClient, auth: AuthService) {
        self.supabase = supabase
        self.auth = auth
        channel = ReleaseChannel.cached
    }

    /// Returns true when the channel actually moved — the caller resets
    /// Sparkle's update cycle so a newly joined tester doesn't wait out the
    /// current 24h interval before the channel is consulted.
    @discardableResult
    func refresh() async -> Bool {
        // Without a session the query returns nothing under RLS, which is
        // indistinguishable from "no longer enrolled" — and dropping a tester
        // off their channel because the app launched before auth restored is
        // how a beta silently stops updating.
        guard auth.currentSupabaseSession != nil else { return false }

        do {
            let rows: [Row] = try await supabase
                .from(Self.tableName)
                .select("channel")
                .limit(1)
                .execute()
                .value
            return apply(rows.first?.channel)
        } catch {
            Log.ui.error("ReleaseChannelStore.refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func apply(_ newChannel: String?) -> Bool {
        let changed = newChannel != channel
        channel = newChannel
        if let newChannel, !newChannel.isEmpty {
            UserDefaults.standard.set(newChannel, forKey: ReleaseChannel.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ReleaseChannel.defaultsKey)
        }
        return changed
    }

    private struct Row: Decodable {
        let channel: String
    }
}
