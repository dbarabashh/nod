import AppKit
import Foundation
import Supabase

/// A colleague's meeting you can listen to, before you have decided to.
struct LiveRoom: Equatable, Decodable {
    /// Withheld until this account has shown it belongs in the meeting.
    ///
    /// Discovery is silent — the host is not told it was asked — and a
    /// conference link is knowable without being in the call, so answering with
    /// a name would make this a way to watch who is recording, asked over and
    /// over. Nil is the ordinary answer for somebody whose calendar the server
    /// cannot see; they learn a recording exists, and the name comes with the
    /// join, which the host is told about and can refuse.
    let hostName: String?
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case hostName = "host_name"
        case startedAt = "started_at"
    }
}

/// The room you are in.
struct JoinedRoom: Equatable, Decodable {
    let listenerID: UUID
    let hostName: String
    let hostMeetingID: UUID
    let startedAt: Date
    /// `joined` once the read is open, `pending` while the host has yet to say
    /// yes. The server decides which: it opens the room by itself when the
    /// caller's own synced calendar carries the same meeting, and asks the host
    /// when it cannot tell.
    ///
    /// Optional because a server that predates the approval flow — or one rolled
    /// back to it — returns no such field, and a required key would turn that
    /// into a decode failure that `join` swallows, leaving a button that does
    /// nothing. Absent means the old behaviour: joining was the whole act.
    let status: String?

    var isPending: Bool {
        status == "pending"
    }

    /// The host said no. Kept as a state of the room rather than dropping back
    /// to nothing: somebody who pressed Join and then watched the screen go
    /// blank has been given an answer they cannot read.
    var isDenied: Bool {
        status == "denied"
    }

    enum CodingKeys: String, CodingKey {
        case listenerID = "listener_id"
        case hostName = "host_name"
        case hostMeetingID = "host_meeting_id"
        case startedAt = "started_at"
        case status
    }

    init(listenerID: UUID, hostName: String, hostMeetingID: UUID, startedAt: Date, status: String = "joined") {
        self.listenerID = listenerID
        self.hostName = hostName
        self.hostMeetingID = hostMeetingID
        self.startedAt = startedAt
        self.status = status
    }
}

/// Somebody asking to listen to this account's recording, whom the server could
/// not vouch for on its own.
struct PendingListener: Equatable, Identifiable, Decodable {
    let id: UUID
    let name: String
    let askedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "listener_id"
        case name = "listener_name"
        case askedAt = "asked_at"
    }
}

/// Listening to a meeting a colleague is recording.
///
/// The read is theirs, not ours: every transcript row arrives under this
/// account's own policy, which the server closes the moment their recording
/// stops. Nothing here has to notice that happening — a fetch simply starts
/// coming back empty, and `hasEnded` is what that looks like from here.
///
/// Discovery and joining are deliberately separate calls. Joining tells the host
/// somebody is listening, so it may only happen because a person pressed a
/// button.
@MainActor
final class RoomListenerService: ObservableObject {
    /// A room that could be joined right now, if any.
    @Published private(set) var available: LiveRoom?
    /// The room this account is listening to.
    @Published private(set) var joined: JoinedRoom?
    /// The host's transcript, as far as it has been read.
    @Published private(set) var entries: [LiveTranscriptEntry] = []
    /// Who is listening to *this* account's own recording.
    @Published private(set) var listeners: [String] = []
    /// Who has asked to listen to *this* account's own recording and is waiting
    /// on an answer. Only the host is ever shown these.
    @Published private(set) var pendingListeners: [PendingListener] = []
    @Published private(set) var isJoining = false
    /// The host stopped: the read has closed and what is on screen is all there
    /// will be.
    @Published private(set) var hasEnded = false

    /// The host's live findings — the same list their own Notes panel is drawn
    /// from, mirrored through `meeting_live_findings`. Read rather than derived:
    /// a second pass over the same transcript would cost a second set of model
    /// calls to arrive at a slightly different answer, and "slightly different"
    /// is the failure — two people in one meeting whose notes disagree.
    @Published private(set) var findings: [LiveFinding] = []

    /// The recap, once the host's machine has written one. Nil while it is still
    /// being made, which is what `isAwaitingSummary` is for: the two states read
    /// identically from here otherwise, and telling somebody "nothing" when the
    /// answer is "not yet" is the whole complaint this exists to fix.
    @Published private(set) var finalSummary: String?
    @Published private(set) var isAwaitingSummary = false

    /// How long to keep asking for the summary after the host stops. A recap is
    /// a single model call over a finished transcript; if it has not landed in
    /// this long, it failed, and a spinner that never resolves is worse than an
    /// honest end to the card.
    private static let summaryWait: TimeInterval = 180
    private static let summaryPollInterval: TimeInterval = 4

    /// How long to keep waiting on a host who has not answered. Long enough that
    /// somebody mid-sentence can finish it before looking at the request, short
    /// enough that an unanswered ask resolves inside the meeting it was made in.
    private static let approvalWait: TimeInterval = 300
    private static let approvalPollInterval: TimeInterval = 3
    /// Comfortably under `LiveMeetingAnalyst`'s own floor between passes, so a
    /// new finding is never more than this far behind the host's own screen.
    private static let findingsMinInterval: TimeInterval = 10

    /// The same ceiling `LiveMeetingAnalyst` puts on its own catch-up: past
    /// this the prompt costs more than the extra context is worth.
    private static let catchUpMaxEntries = 500

    private let supabase: SupabaseClient?
    private let llm: LLMProxyClient?
    private var channel: RealtimeChannelV2?
    private var pump: Task<Void, Never>?
    private var summaryPoll: Task<Void, Never>?
    private var approvalPoll: Task<Void, Never>?
    private var lastLookNote: String?
    private var lastFindingsFetch: Date?
    private var sleepObserver: NSObjectProtocol?

    init(supabase: SupabaseClient?, llm: LLMProxyClient? = nil) {
        self.supabase = supabase
        self.llm = llm
        observeSleep()
    }

    /// A closed lid leaves the room.
    ///
    /// The server would work this out on its own — a listener whose lease stops
    /// being touched goes stale within ninety seconds — but "eventually" is the
    /// wrong answer to the one thing this feature must never get wrong: the host
    /// is told by name who is listening, and a name that lingers after somebody
    /// has shut their laptop says they are still in the room when they are not.
    ///
    /// Best-effort by nature. There may not be time for the round trip, which is
    /// exactly why the server-side staleness rule stays as the backstop rather
    /// than being replaced by this.
    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.joined != nil else { return }
                Log.ui.info("sleep: leaving the live room")
                Task { await self.leave() }
            }
        }
    }

    /// "What did I miss?" — the point of joining twenty minutes late.
    ///
    /// Runs over the transcript already fetched rather than through
    /// `LiveMeetingAnalyst`: that object is built around a recording this
    /// account is making, with a `TranscriptStore` a listener does not have. The
    /// prompt is the same one the host's own Summarize chip uses, and it is
    /// handed the host's findings as memory, so the two answers are not merely
    /// the same kind of thing — they are built from the same two inputs.
    func catchMeUp(language: AppLanguage) async throws -> String {
        guard let llm else { throw AskUnavailable() }
        let prompt = PromptLibrary.buildCatchUp(
            transcript: recentTranscript,
            known: LiveFinding.notes(from: findings),
            language: language
        )
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.CatchUpResult.self,
            primaryModel: llm.chatModel
        )
        return result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The host's transcript as the prompts want it. One definition, because the
    /// `[Me]`/`[Them]` tag is what every playbook rule in `PromptLibrary` keys
    /// on — two copies drifting means the host's answers and the listener's
    /// stop being built from the same shape of context.
    private var recentTranscript: String {
        entries
            .suffix(Self.catchUpMaxEntries)
            .map { "[\($0.label)]: \($0.text)" }
            .joined(separator: "\n")
    }

    /// The listener's own question, about somebody else's meeting.
    ///
    /// Throwing rather than publishing its own state, because the caller already
    /// has somewhere to put the answer: `NotchModel.runAsk` owns the
    /// composing → loading → answered walk for the person recording, and a
    /// second copy of it here would be a second thing to keep in step.
    ///
    /// The answer is not written anywhere. A listener's question is theirs, and
    /// `chat_messages` belongs to the host's meeting — putting it there would
    /// mean everyone in the room reading each other's questions, which nobody
    /// asked for and which the host cannot switch off.
    func ask(_ question: String, thread: AskThread = AskThread(), language: AppLanguage) async throws -> String {
        guard let llm else { throw AskUnavailable() }
        let prompt = PromptLibrary.buildAsk(
            question: question,
            transcript: recentTranscript,
            known: LiveFinding.notes(from: findings),
            thread: thread,
            language: language
        )
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.AskResult.self,
            primaryModel: llm.chatModel
        )
        return result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only reachable in a build with no proxy configured — a preview, a test.
    struct AskUnavailable: Error {}

    deinit {
        pump?.cancel()
        summaryPoll?.cancel()
        approvalPoll?.cancel()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

    // MARK: - Discovery

    /// Asks whether a colleague is already recording the meeting described by
    /// this invitation. Quiet by design: nobody is told this was asked.
    func lookForRoom(_ identity: RoomIdentity) async {
        guard let supabase, joined == nil else { return }
        do {
            let rooms: [LiveRoom] = try await supabase
                .rpc("find_live_room", params: Identity(identity))
                .execute()
                .value
            available = rooms.first
            // The answer, not just the failure. A successful call returning
            // nothing looked identical to a call never made, which is exactly
            // the ambiguity that made this take three attempts to diagnose.
            let answer = rooms.first.map { "found \($0.hostName ?? "somebody")" }
                ?? "nobody is recording it"
            if answer != lastLookNote {
                lastLookNote = answer
                Log.ui.info("live room: \(answer)")
            }
        } catch {
            lastLookNote = nil
            Log.ui.error("RoomListenerService.lookForRoom failed: \(error.localizedDescription)")
        }
    }

    func forgetRoom() {
        available = nil
    }

    // MARK: - Joining

    func join(_ identity: RoomIdentity) async {
        guard let supabase, joined == nil else { return }
        isJoining = true
        defer { isJoining = false }
        do {
            let rooms: [JoinedRoom] = try await supabase
                .rpc("join_live_room", params: Identity(identity))
                .execute()
                .value
            guard let room = rooms.first else { return }
            joined = room
            available = nil
            hasEnded = false
            findings = []
            lastFindingsFetch = nil
            finalSummary = nil
            isAwaitingSummary = false
            // A pending request reads nothing until the host answers, so there
            // is no transcript to fetch and no channel worth holding open. The
            // host's answer arrives on this account's own access topic, which
            // `awaitApproval` is watching.
            guard !room.isPending else {
                Log.ui.info("asked \(room.hostName) to listen; waiting for an answer")
                awaitApproval(of: room)
                return
            }
            Log.ui.info("joined live room hosted by \(room.hostName)")
            await refreshTranscript()
            await subscribe(to: room.hostMeetingID)
        } catch {
            Log.ui.error("RoomListenerService.join failed: \(error.localizedDescription)")
        }
    }

    /// Watches this account's own listener row until the host answers.
    ///
    /// Polled rather than pushed: the row is readable under "listeners read
    /// their own row", and a realtime subscription for a single boolean that
    /// flips once would be a channel to tear down on every path that already has
    /// one too many. A refusal keeps the room rather than clearing it, because a
    /// request that was refused and a request still waiting look identical from
    /// an empty screen, and leaving somebody on "still waiting" forever is the
    /// failure this has to avoid.
    private func awaitApproval(of room: JoinedRoom) {
        approvalPoll?.cancel()
        approvalPoll = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.approvalWait)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(Self.approvalPollInterval * 1_000_000_000))
                guard let self, let supabase, joined?.listenerID == room.listenerID
                else { return }
                do {
                    struct Row: Decodable {
                        let status: String
                        let left_at: Date?
                    }
                    let rows: [Row] = try await supabase
                        .from("room_listeners")
                        .select("status, left_at")
                        .eq("id", value: room.listenerID)
                        .execute()
                        .value
                    // Asked again after the round trip, not only before it: a
                    // person can press Leave while this read is in flight, and
                    // acting on the answer then would re-join them to a room the
                    // server has already closed.
                    guard !Task.isCancelled, joined?.listenerID == room.listenerID else { return }
                    guard let row = rows.first else { return }
                    if row.status == "joined" {
                        joined = JoinedRoom(
                            listenerID: room.listenerID,
                            hostName: room.hostName,
                            hostMeetingID: room.hostMeetingID,
                            startedAt: room.startedAt,
                            status: "joined"
                        )
                        Log.ui.info("\(room.hostName) let us into the room")
                        await refreshTranscript()
                        await subscribe(to: room.hostMeetingID)
                        return
                    }
                    if row.status == "denied" || row.left_at != nil {
                        Log.ui.info("the request to listen was declined")
                        joined = JoinedRoom(
                            listenerID: room.listenerID,
                            hostName: room.hostName,
                            hostMeetingID: room.hostMeetingID,
                            startedAt: room.startedAt,
                            status: "denied"
                        )
                        return
                    }
                } catch {
                    Log.ui.error("RoomListenerService.awaitApproval failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func leave() async {
        guard let supabase, let room = joined else { return }
        await teardown()
        summaryPoll?.cancel()
        summaryPoll = nil
        approvalPoll?.cancel()
        approvalPoll = nil
        joined = nil
        entries = []
        hasEnded = false
        findings = []
        finalSummary = nil
        isAwaitingSummary = false
        do {
            struct Params: Encodable { let p_listener: UUID }
            _ = try await supabase
                .rpc("leave_live_room", params: Params(p_listener: room.listenerID))
                .execute()
            Log.ui.info("left live room")
        } catch {
            Log.ui.error("RoomListenerService.leave failed: \(error.localizedDescription)")
        }
    }

    // MARK: - The host's side

    /// Who is listening to a recording this account is making.
    func refreshListeners(hostMeetingID: UUID) async {
        guard let supabase else { return }
        struct Params: Encodable { let p_meeting: UUID }
        struct Row: Decodable { let listener_name: String }
        do {
            let rows: [Row] = try await supabase
                .rpc("room_listeners_of", params: Params(p_meeting: hostMeetingID))
                .execute()
                .value
            listeners = rows.map(\.listener_name)
        } catch {
            Log.ui.error("RoomListenerService.refreshListeners failed: \(error.localizedDescription)")
        }
    }

    /// Who has asked to listen and is still waiting.
    ///
    /// Only reaches a request the server could not settle by itself: when the
    /// asker's own synced calendar carries this meeting, they are already in and
    /// never appear here. So this list is exactly the people whose claim to be
    /// in the room only the host can confirm.
    func refreshPendingListeners(hostMeetingID: UUID) async {
        guard let supabase else { return }
        struct Params: Encodable { let p_meeting: UUID }
        do {
            let rows: [PendingListener] = try await supabase
                .rpc("pending_room_listeners", params: Params(p_meeting: hostMeetingID))
                .execute()
                .value
            pendingListeners = rows
        } catch {
            Log.ui.error("RoomListenerService.refreshPendingListeners failed: \(error.localizedDescription)")
        }
    }

    func approve(_ listener: PendingListener, hostMeetingID: UUID) async {
        await answer("approve_room_listener", listener, hostMeetingID)
    }

    func deny(_ listener: PendingListener, hostMeetingID: UUID) async {
        await answer("deny_room_listener", listener, hostMeetingID)
    }

    private func answer(_ rpc: String, _ listener: PendingListener, _ hostMeetingID: UUID) async {
        guard let supabase else { return }
        struct Params: Encodable { let p_listener: UUID }
        // Off the list first: the answer is the host's and should land on their
        // own screen immediately, not after a round trip they are watching.
        pendingListeners.removeAll { $0.id == listener.id }
        do {
            _ = try await supabase
                .rpc(rpc, params: Params(p_listener: listener.id))
                .execute()
            await refreshListeners(hostMeetingID: hostMeetingID)
        } catch {
            Log.ui.error("RoomListenerService.\(rpc) failed: \(error.localizedDescription)")
            await refreshPendingListeners(hostMeetingID: hostMeetingID)
        }
    }

    func clearListeners() {
        guard !listeners.isEmpty || !pendingListeners.isEmpty else { return }
        listeners = []
        pendingListeners = []
    }

    // MARK: - The transcript

    /// Only what arrived since the last read. The first read after joining has
    /// no floor, so it still fetches the whole thing — which is the point of
    /// arriving late — but every poke after that carries one line, not the
    /// transcript so far. Re-reading all of it on every new line made an hour's
    /// listening quadratic in the number of lines said.
    private func refreshTranscript() async {
        guard let supabase, let room = joined else { return }
        do {
            let rows: [LiveTranscriptEntry] = try await supabase
                .from("meeting_transcripts")
                .select("idx, speaker, source, text, ts")
                .eq("meeting_id", value: room.hostMeetingID)
                .gt("idx", value: entries.last?.idx ?? -1)
                .order("idx", ascending: true)
                .execute()
                .value
            if rows.isEmpty, !entries.isEmpty, await hasClosed(room) {
                hasEnded = true
                await teardown()
                awaitSummary(of: room)
                return
            }
            entries.append(contentsOf: rows)
            await refreshFindings(room)
        } catch {
            Log.ui.error("RoomListenerService.refreshTranscript failed: \(error.localizedDescription)")
        }
    }

    /// The host's Notes, as far as their machine has published them.
    ///
    /// Read on the same poke as the transcript rather than on a timer of its
    /// own: a finding is raised *because* something was said, so the signal that
    /// there is new transcript is the same signal that there may be a new note.
    ///
    /// Silent on failure, and not `throws`: an environment whose schema predates
    /// `20260816260000` has no such table, and a listener who can follow the
    /// meeting but sees no notes is a far better outcome than one whose whole
    /// read falls over. That exact mistake — one optional lookup throwing out of
    /// a refresh and taking the working half with it — cost an afternoon on
    /// 2026-08-16.
    private func refreshFindings(_ room: JoinedRoom) async {
        guard let supabase else { return }
        // Throttled, because the two sides tick at very different rates: the
        // transcript pokes on every settled chunk, while the live pass cannot
        // raise or retire a finding faster than its own minimum interval. Left
        // ungated this refetched the whole list hundreds of times an hour to
        // learn nothing. No staleness is visible at this interval.
        if let last = lastFindingsFetch, Date().timeIntervalSince(last) < Self.findingsMinInterval {
            return
        }
        lastFindingsFetch = Date()
        do {
            let rows: [LiveFindingRow] = try await supabase
                .from("meeting_live_findings")
                .select("meeting_id, id, kind, tier, text, deadline, spoken_at, found_at, state, revision_of")
                .eq("meeting_id", value: room.hostMeetingID)
                .order("found_at", ascending: true)
                .execute()
                .value
            findings = rows.compactMap(\.finding)
        } catch {
            Log.ui.error("RoomListenerService.refreshFindings failed: \(error.localizedDescription)")
        }
    }

    /// After the host presses End: wait for their recap and show it.
    ///
    /// A poll rather than a subscription, because there is nothing to subscribe
    /// to — the host's machine writes the summary through an ordinary update
    /// when its own recap call returns, and adding a broadcast for it would mean
    /// the host announcing something it has no reason to announce.
    private func awaitSummary(of room: JoinedRoom) {
        guard let supabase, finalSummary == nil else { return }
        isAwaitingSummary = true
        summaryPoll?.cancel()
        summaryPoll = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.summaryWait)
            struct Row: Decodable { let summary: String }
            while !Task.isCancelled, Date() < deadline {
                do {
                    let rows: [Row] = try await supabase
                        .from("meetings")
                        .select("summary")
                        .eq("id", value: room.hostMeetingID)
                        .limit(1)
                        .execute()
                        .value
                    let summary = rows.first?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let summary, !summary.isEmpty {
                        guard let self, !Task.isCancelled else { return }
                        finalSummary = summary
                        isAwaitingSummary = false
                        Log.ui.info("live room: the host's summary arrived")
                        return
                    }
                } catch {
                    // Expected until the migration lands, and expected forever in
                    // an environment where the host never finalized. Either way
                    // the loop's own deadline is what ends it.
                    Log.ui.error("RoomListenerService.awaitSummary failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.summaryPollInterval * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            isAwaitingSummary = false
            Log.ui.info("live room: gave up waiting for the host's summary")
        }
    }

    /// Nothing new could mean nothing was said, or it could mean the read has
    /// closed because the host stopped. One row tells the two apart.
    private func hasClosed(_ room: JoinedRoom) async -> Bool {
        guard let supabase else { return false }
        do {
            let probe: [LiveTranscriptEntry] = try await supabase
                .from("meeting_transcripts")
                .select("idx, speaker, source, text, ts")
                .eq("meeting_id", value: room.hostMeetingID)
                .limit(1)
                .execute()
                .value
            return probe.isEmpty
        } catch {
            return false
        }
    }

    /// The channel carries no transcript — only that there is more of it. What a
    /// person may read stays decided by the table's own policy, in one place.
    private func subscribe(to hostMeetingID: UUID) async {
        guard let supabase else { return }
        await teardown()
        let channel = supabase.channel("room:\(hostMeetingID.uuidString.lowercased())") {
            $0.isPrivate = true
        }
        self.channel = channel
        let stream = channel.broadcastStream(event: "access")
        await channel.subscribe()
        pump = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                await refreshTranscript()
            }
        }
    }

    /// Stops the live read. Deliberately leaves `summaryPoll` alone: it starts
    /// *because* the read closed, so cancelling it here would end the wait for
    /// the summary at the exact moment the wait begins. `leave()` is what ends
    /// it, which is the one place a person has actually said they are done.
    private func teardown() async {
        pump?.cancel()
        pump = nil
        if let channel {
            await channel.unsubscribe()
            self.channel = nil
        }
    }

    private struct Identity: Encodable {
        let p_ical_uid: String?
        let p_conference_url: String?

        init(_ identity: RoomIdentity) {
            p_ical_uid = identity.icalUID
            p_conference_url = identity.conferenceURL?.absoluteString
        }
    }
}

/// One line of somebody else's live transcript.
struct LiveTranscriptEntry: Equatable, Decodable, Identifiable {
    let idx: Int
    let speaker: Int?
    /// Whose side of the call this line came from. Carried because every
    /// playbook rule in `PromptLibrary` keys on the `[Me]`/`[Them]` tag — a
    /// catch-up built from bare text asks the model to summarise a conversation
    /// without telling it who said what.
    let source: String
    let text: String
    let ts: Date

    var label: String {
        TranscriptSource(rawValue: source)?.label ?? source
    }

    var id: Int {
        idx
    }
}

#if DEBUG
    extension RoomListenerService {
        static func preview(
            available: LiveRoom? = nil,
            joined: JoinedRoom? = nil,
            listeners: [String] = [],
            ended: Bool = false,
            summary: String? = nil,
            findings: [LiveFinding] = []
        ) -> RoomListenerService {
            let service = RoomListenerService(supabase: nil)
            service.available = available
            service.joined = joined
            service.listeners = listeners
            service.hasEnded = ended
            service.finalSummary = summary
            service.isAwaitingSummary = ended && summary == nil
            service.findings = findings
            return service
        }
    }
#endif
