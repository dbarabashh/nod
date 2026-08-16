import Foundation
import Supabase

/// A colleague's meeting you can listen to, before you have decided to.
struct LiveRoom: Equatable, Decodable {
    let hostName: String
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

    enum CodingKeys: String, CodingKey {
        case listenerID = "listener_id"
        case hostName = "host_name"
        case hostMeetingID = "host_meeting_id"
        case startedAt = "started_at"
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
    @Published private(set) var isJoining = false
    /// The host stopped: the read has closed and what is on screen is all there
    /// will be.
    @Published private(set) var hasEnded = false

    /// What the listener missed, once they have asked for it.
    @Published private(set) var catchUp: String?
    @Published private(set) var isCatchingUp = false

    /// The same ceiling `LiveMeetingAnalyst` puts on its own catch-up: past
    /// this the prompt costs more than the extra context is worth.
    private static let catchUpMaxEntries = 500

    private let supabase: SupabaseClient?
    private let llm: LLMProxyClient?
    private var channel: RealtimeChannelV2?
    private var pump: Task<Void, Never>?
    private var lastLookNote: String?

    init(supabase: SupabaseClient?, llm: LLMProxyClient? = nil) {
        self.supabase = supabase
        self.llm = llm
    }

    /// "What did I miss?" — the point of joining twenty minutes late.
    ///
    /// Runs over the transcript already fetched rather than through
    /// `LiveMeetingAnalyst`: that object is built around a recording this
    /// account is making, with a `TranscriptStore` a listener does not have and
    /// findings a listener never produced. The prompt is the same one the host's
    /// own Summarize chip uses, so the two answers are the same kind of thing.
    func catchMeUp(language: AppLanguage) async {
        guard let llm, !entries.isEmpty, !isCatchingUp else { return }
        isCatchingUp = true
        defer { isCatchingUp = false }
        let transcript = entries
            .suffix(Self.catchUpMaxEntries)
            .map { "[\($0.label)]: \($0.text)" }
            .joined(separator: "\n")
        let prompt = PromptLibrary.buildCatchUp(transcript: transcript, known: [], language: language)
        do {
            let result = try await llm.completeJSON(
                system: prompt.system,
                user: prompt.user,
                as: PromptLibrary.CatchUpResult.self,
                primaryModel: llm.chatModel
            )
            catchUp = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.llm.error("RoomListenerService.catchMeUp failed: \(error.localizedDescription)")
        }
    }

    deinit {
        pump?.cancel()
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
            let answer = rooms.first.map { "found \($0.hostName)" } ?? "nobody is recording it"
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
            Log.ui.info("joined live room hosted by \(room.hostName)")
            await refreshTranscript()
            await subscribe(to: room.hostMeetingID)
        } catch {
            Log.ui.error("RoomListenerService.join failed: \(error.localizedDescription)")
        }
    }

    func leave() async {
        guard let supabase, let room = joined else { return }
        await teardown()
        joined = nil
        entries = []
        catchUp = nil
        hasEnded = false
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

    func clearListeners() {
        guard !listeners.isEmpty else { return }
        listeners = []
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
                return
            }
            entries.append(contentsOf: rows)
        } catch {
            Log.ui.error("RoomListenerService.refreshTranscript failed: \(error.localizedDescription)")
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
        static func preview(available: LiveRoom? = nil, joined: JoinedRoom? = nil, listeners: [String] = []) -> RoomListenerService {
            let service = RoomListenerService(supabase: nil)
            service.available = available
            service.joined = joined
            service.listeners = listeners
            return service
        }
    }
#endif
