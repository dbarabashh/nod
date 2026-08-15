import Foundation
import Supabase

/// Listens for "your access changed" and re-asks.
///
/// Access is granted and revoked on somebody else's Mac. Without a channel this
/// app learns about it only when it next asks, which is why a project could sit
/// in the sidebar after the share behind it was gone — the rows were already
/// unreachable on the server, but the window kept drawing what it had.
///
/// Three topics, matching how the server sends: your own, plus one per audience
/// you belong to. `user:` is the one that matters most — you pass its policy
/// whether or not you are still in the organization, so the message telling you
/// that you were removed is one you are still entitled to receive. An audience
/// topic could not do that, because losing the membership is what disqualifies
/// you from reading it.
///
/// Nothing arrives except the fact that something moved. The refresh that
/// follows runs under the person's own permissions, so a channel cannot show
/// anybody a row a query would not.
@MainActor
final class AccessChannel {
    private let supabase: SupabaseClient
    private let onChange: @MainActor () async -> Void

    private var channels: [RealtimeChannelV2] = []
    private var listeners: [Task<Void, Never>] = []
    private var topics: [String] = []

    init(supabase: SupabaseClient, onChange: @escaping @MainActor () async -> Void) {
        self.supabase = supabase
        self.onChange = onChange
    }

    /// Rebuilt only when the set of audiences actually changed.
    ///
    /// This is called after every refresh, and most refreshes change nothing
    /// about which topics matter — a folder being shared does not move anybody
    /// between teams. Rebuilding regardless tore down the very listener that was
    /// running the refresh, so the first message arrived and the second never
    /// did: the subscription had cancelled itself while handling the first.
    ///
    /// Rebuilt rather than amended when it genuinely differs, because a channel
    /// left subscribed to a team somebody just left is the kind of leak that
    /// survives review — nothing about it looks wrong.
    func resubscribe(orgIDs: [UUID], teamIDs: [UUID]) async {
        guard let userID = supabase.auth.currentUser?.id else { return }

        var wanted = ["user:\(userID.uuidString.lowercased())"]
        wanted += orgIDs.map { "org:\($0.uuidString.lowercased())" }
        wanted += teamIDs.map { "team:\($0.uuidString.lowercased())" }
        wanted.sort()

        guard wanted != topics else { return }
        await teardown()
        topics = wanted

        for topic in wanted {
            let channel = supabase.channel(topic) { $0.isPrivate = true }
            let stream = channel.broadcastStream(event: "access")
            listeners.append(Task { [weak self] in
                for await _ in stream {
                    guard let self else { return }
                    Log.ui.info("access change received")
                    await onChange()
                }
            })
            await channel.subscribe()
            channels.append(channel)
        }
        Log.ui.info("access channel listening topics=\(wanted.count)")
    }

    func teardown() async {
        topics = []
        listeners.forEach { $0.cancel() }
        listeners = []
        for channel in channels {
            await channel.unsubscribe()
        }
        channels = []
    }
}
