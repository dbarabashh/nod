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

/// One build offered by the feed this app is pointed at.
struct FeedBuild: Equatable {
    let version: String
    let build: Int
    /// nil is the default channel, which every account sees.
    var channel: String?

    var label: String {
        "\(version) (\(build))"
    }
}

/// Sparkle's view of that cache, and what the newest offered build is.
///
/// An empty set is Sparkle's default and means "untagged items only" — what
/// every account that was never enrolled gets.
///
/// The feed is never named here. `SUFeedURL` comes from `NOD_FEED_URL`, which
/// the build configuration sets: production points at `appcast.xml`, Sandbox at
/// `appcast-sandbox.xml`, and project.yml is explicit that the two must never
/// cross. Reading the answer from Sparkle rather than fetching a URL of our own
/// is what keeps that true — a production build cannot report a sandbox build
/// as its latest, because it never loads that feed.
@MainActor
final class UpdaterChannelDelegate: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// The newest build the feed offers, once one check has completed.
    @Published private(set) var latest: FeedBuild?

    /// Runs a silent check — no UI, no prompt. Set by the composition root,
    /// which owns the updater this delegate belongs to.
    var refresh: () -> Void = {}

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard let channel = ReleaseChannel.cached, !channel.isEmpty else { return [] }
        return [channel]
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let offered = appcast.items.compactMap { item -> FeedBuild? in
            guard let build = Int(item.versionString) else { return nil }
            return FeedBuild(version: item.displayVersionString, build: build, channel: item.channel)
        }
        let newest = Self.newest(of: offered, allowing: allowedChannels(for: updater))
        Task { @MainActor [weak self] in self?.latest = newest }
    }

    /// The highest-numbered item this account is allowed to see.
    ///
    /// `SUAppcast.items` is documented as feed order, not version order, so the
    /// maximum is taken rather than the first. Channel filtering is repeated
    /// here because this reads the whole feed: Sparkle applies `allowedChannels`
    /// when it decides what to *offer*, and an item on a channel this account is
    /// not in must not be reported as its latest either.
    nonisolated static func newest(of offered: [FeedBuild], allowing channels: Set<String>) -> FeedBuild? {
        offered
            .filter { $0.channel.map(channels.contains) ?? true }
            .max { $0.build < $1.build }
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
