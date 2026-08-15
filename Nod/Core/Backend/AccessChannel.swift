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

    init(supabase: SupabaseClient, onChange: @escaping @MainActor () async -> Void) {
        self.supabase = supabase
        self.onChange = onChange
    }

    /// Rebuilt rather than amended when membership changes: the set of audiences
    /// is small, and a channel left subscribed to a team somebody just left is
    /// the kind of leak that survives review because nothing looks wrong.
    func resubscribe(orgIDs: [UUID], teamIDs: [UUID]) async {
        await teardown()
        guard let userID = supabase.auth.currentUser?.id else { return }

        var topics = ["user:\(userID.uuidString.lowercased())"]
        topics += orgIDs.map { "org:\($0.uuidString.lowercased())" }
        topics += teamIDs.map { "team:\($0.uuidString.lowercased())" }

        for topic in topics {
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
        Log.ui.info("access channel listening topics=\(topics.count)")
    }

    func teardown() async {
        listeners.forEach { $0.cancel() }
        listeners = []
        for channel in channels {
            await channel.unsubscribe()
        }
        channels = []
    }
}
