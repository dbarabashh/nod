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
    /// Rebuilds run one after another. Two pokes arriving together each start a
    /// refresh, each refresh ends by re-subscribing, and two rebuilds
    /// interleaving at their `await`s would leave a second channel and a second
    /// listener per topic — after which every poke does everything twice.
    private var rebuild: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshQueued = false

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
        let previous = rebuild
        let work = Task { @MainActor [weak self] in
            await previous?.value
            await self?.apply(orgIDs: orgIDs, teamIDs: teamIDs)
        }
        rebuild = work
        await work.value
    }

    private func apply(orgIDs: [UUID], teamIDs: [UUID]) async {
        guard let userID = supabase.auth.currentUser?.id else { return }

        var wanted = ["user:\(userID.uuidString.lowercased())"]
        wanted += orgIDs.map { "org:\($0.uuidString.lowercased())" }
        wanted += teamIDs.map { "team:\($0.uuidString.lowercased())" }
        wanted.sort()

        guard wanted != topics else { return }
        topics = wanted
        await closeChannels()
        // The account can change across that suspension — a sign-out queues a
        // teardown behind this rebuild, but a *different* person signing in
        // would have this loop subscribe them to the last one's topics.
        guard supabase.auth.currentUser?.id == userID else {
            topics = []
            return
        }

        for topic in wanted {
            let channel = supabase.channel(topic) { $0.isPrivate = true }
            let stream = channel.broadcastStream(event: "access")
            listeners.append(Task { [weak self] in
                for await _ in stream {
                    guard let self else { return }
                    Log.ui.info("access change received")
                    await pokeArrived()
                }
            })
            await channel.subscribe()
            channels.append(channel)
        }
        Log.ui.info("access channel listening topics=\(wanted.count)")
    }

    /// Collapses a burst into one pass.
    ///
    /// One gesture can send several pokes — filing a session into three projects
    /// is three rows — and each of them costs a full re-read of the
    /// organizations, the folders, the grants and the library. Running that
    /// three times answers the same question three times; running it once more
    /// after the last one arrives answers it correctly.
    private func pokeArrived() async {
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            // A moment before starting, so the pokes one gesture produces are
            // one pass rather than two. Filing a session into three projects is
            // three rows and three messages; so is the poke a device causes
            // itself, which arrives just behind the change it already applied.
            try? await Task.sleep(nanoseconds: Self.settleWindow)
            if refreshQueued { continue }
            await onChange()
        } while refreshQueued
    }

    /// Long enough to absorb the messages of one gesture, short enough that a
    /// colleague's revocation still reads as immediate.
    private static let settleWindow: UInt64 = 300_000_000

    /// Queued behind any rebuild in flight, never alongside one.
    ///
    /// A rebuild is five round trips and a subscribe, and a sign-out arriving
    /// mid-way used to close the channels the rebuild was about to open — after
    /// which the rebuild finished, re-opened them under the departing session,
    /// and left `topics` claiming a set that the next sign-in would then see as
    /// unchanged and decline to build. The channel stayed dead for the rest of
    /// the process.
    func teardown() async {
        let previous = rebuild
        let work = Task { @MainActor [weak self] in
            await previous?.value
            self?.topics = []
            await self?.closeChannels()
        }
        rebuild = work
        await work.value
    }

    private func closeChannels() async {
        listeners.forEach { $0.cancel() }
        listeners = []
        for channel in channels {
            await channel.unsubscribe()
        }
        channels = []
    }
}
