import Combine
import Foundation
import Supabase

/// One retrieved transcript chunk from cross-session search.
struct RetrievedChunk: Decodable, Identifiable {
    let meetingID: UUID
    let content: String
    let similarity: Double

    var id: String {
        "\(meetingID.uuidString):\(content.hashValue)"
    }

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case content
        case similarity
    }
}

/// Cross-session semantic memory. Chunks a finished session's transcript and
/// hands it to the proxy for server-side embedding + storage; retrieves the
/// closest chunks for a free-text query the same way. All vector work lives
/// server-side (gte-small), scoped to the owner by RLS.
@MainActor
final class KnowledgeStore: ObservableObject {
    private let llm: LLMProxyClient
    private let supabase: SupabaseClient

    /// ~1200 chars ≈ a few minutes of dialogue — small enough to be a precise
    /// retrieval unit, large enough to carry context.
    private static let targetChunkChars = 1200

    init(llm: LLMProxyClient, supabase: SupabaseClient) {
        self.llm = llm
        self.supabase = supabase
    }

    /// Indexes the session's transcript for cross-session search. The proxy
    /// embeds each chunk (gte-small) and stores the vectors. Best-effort:
    /// a failure just means this session won't surface in search, never a
    /// broken save.
    // MARK: - Cache

    private struct CacheKey: Hashable {
        let query: String
        let matchCount: Int
        let meetingID: UUID?
        let meetingIDs: [UUID]?
    }

    private var cache: [CacheKey: KnowledgeHits] = [:]
    private var cacheOrder: [CacheKey] = []

    /// Small enough to stay bounded, big enough to cover a typing session and a
    /// few chat turns. Results only go stale when the corpus changes, which is
    /// exactly when `index`/`reindex` clear it.
    private static let cacheLimit = 60

    private func store(_ hits: KnowledgeHits, for key: CacheKey) {
        cache[key] = hits
        touch(key)
        if cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Moves a key to the most-recent end. Without this the eviction order is
    /// insertion order, so a query served on every keystroke is dropped after
    /// 60 distinct searches purely for being old.
    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    /// Not `private`: a trashed or restored meeting can change which chunks a
    /// cached result set is allowed to surface, and the cache has no way to
    /// notice that on its own — something outside this store has to tell it.
    func invalidateCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func index(meetingID: UUID, transcript: String) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        let chunks = Self.chunk(transcript)
        guard !chunks.isEmpty else { return }
        // New content means every cached answer set is potentially incomplete.
        invalidateCache()
        Log.ui.info("KnowledgeStore.index meeting=\(meetingID.uuidString) chunks=\(chunks.count)")
        do {
            try await llm.indexSession(meetingID: meetingID, chunks: chunks)
        } catch {
            Log.ui.error("KnowledgeStore.index failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Retrieves the closest chunks to a query. `meetingID` scopes to one
    /// session (long-meeting retrieval); nil searches across all sessions.
    /// Cross-session drops the weak tail to avoid confabulation; within a
    /// single known session we keep the best chunks regardless, since they're
    /// the only source the user is asking about.
    /// `embedText`, when set, is what gets embedded for the vector match (the
    /// HyDE hypothetical answer); `query` is still used for entity matching and
    /// scoping. Nil falls back to embedding the query itself.
    func search(query: String, matchCount: Int = 8, meetingID: UUID? = nil, meetingIDs: [UUID]? = nil, embedText: String? = nil) async -> [
        RetrievedChunk
    ] {
        await searchWithConcepts(
            query: query,
            matchCount: matchCount,
            meetingID: meetingID,
            meetingIDs: meetingIDs,
            embedText: embedText
        ).chunks
    }

    /// The two retrieval stages together: distilled concepts for entities the
    /// question names, then transcript chunks. Same call, same cache — `search`
    /// above is this with the concepts dropped, kept for the callers that only
    /// ever wanted passages.
    func searchWithConcepts(
        query: String,
        matchCount: Int = 8,
        meetingID: UUID? = nil,
        meetingIDs: [UUID]? = nil,
        embedText: String? = nil
    ) async -> KnowledgeHits {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        // Every miss is an embedding plus a pgvector scan, billed per call. The
        // launcher searches on each pause in typing and a chat turn re-searches
        // its own follow-ups, so the same query comes back constantly within a
        // session — serve those from memory.
        // Deliberately NOT keyed on `embedText`: that's the HyDE passage, which
        // the model rewrites on every turn, so including it gave the chat path
        // — the expensive one — a key that could never repeat.
        let cacheKey = CacheKey(
            query: trimmed,
            matchCount: matchCount,
            meetingID: meetingID,
            meetingIDs: meetingIDs
        )
        if let hit = cache[cacheKey] {
            touch(cacheKey)
            return hit
        }
        #if DEBUG
            if DemoMode.isEnabled {
                return KnowledgeHits(
                    chunks: DemoData.knowledgeChunks(
                        query: trimmed,
                        matchCount: matchCount,
                        meetingID: meetingID,
                        meetingIDs: meetingIDs
                    ),
                    concepts: []
                )
            }
        #endif
        do {
            let results = try await llm.searchKnowledge(
                query: trimmed,
                matchCount: matchCount,
                meetingID: meetingID,
                meetingIDs: meetingIDs,
                embedText: embedText
            )
            // The similarity floor guards chunks alone. Concepts arrive
            // entity-scoped and already distilled; a low cosine against a HyDE
            // passage says nothing about whether "Atlas ships 15 Oct" answers
            // a question that named Atlas.
            let filtered = meetingID == nil
                ? results.chunks.filter { $0.similarity >= Self.minSimilarity }
                : results.chunks
            let hits = KnowledgeHits(chunks: filtered, concepts: results.concepts)
            store(hits, for: cacheKey)
            return hits
        } catch LLMProxyClient.ClientError.entitlementRequired {
            // Expected gated state, not a failure: on a lapsed plan the proxy
            // 403s `search` and the client has already surfaced the paywall.
            // Fail soft to [] — the chat call that follows enforces entitlement
            // again and is the real gate, so don't log this as an error.
            Log.ui.info("KnowledgeStore.search gated (entitlement) — returning no chunks")
            return .empty
        } catch {
            Log.ui.error("KnowledgeStore.search failed: \(error.localizedDescription)")
            return .empty
        }
    }

    // MARK: - Distillation

    /// What the last distillation pass did, for the recap card's knowledge
    /// line. Keyed by meeting so a card only reads its own session's outcome.
    struct DistillationOutcome: Equatable {
        let meetingID: UUID
        let counts: DistillCounts
    }

    @Published private(set) var lastDistillation: DistillationOutcome?
    private var distillationSchedule = DistillationSchedule()

    /// Asks the server to distill a finished session into concepts.
    /// Best-effort like `index`: the meeting is saved either way, and a failed
    /// pass costs one session's facts, not the session.
    func distill(meetingID: UUID, skipCompleted: Bool = false) async {
        guard !Task.isCancelled, distillationSchedule.begin(meetingID) else { return }
        defer { distillationSchedule.finish(meetingID) }
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        do {
            let counts = try await llm.distill(meetingID: meetingID, skipCompleted: skipCompleted)
            distillationSchedule.succeeded(meetingID)
            if counts.changed > 0 {
                // New facts change what any cached search may cite.
                invalidateCache()
            }
            lastDistillation = DistillationOutcome(meetingID: meetingID, counts: counts)
            Log.ui.info(
                "KnowledgeStore.distill meeting=\(meetingID.uuidString) added=\(counts.added) updated=\(counts.updated) retired=\(counts.retired) noop=\(counts.noop)"
            )
        } catch let error as LLMProxyClient.DistillationRateLimit {
            distillationSchedule.rateLimited(for: error.retryAfter)
            Log.ui.info("KnowledgeStore.distill deferred after provider rate limit")
        } catch {
            distillationSchedule.failed(meetingID)
            Log.ui.error("KnowledgeStore.distill failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// How far back the one-time backfill reaches. Enough that the knowledge
    /// layer starts with the user's recent working memory instead of empty;
    /// small enough that a first launch doesn't spend an hour of model calls.
    /// Newest first, so the sessions the user will actually ask about are
    /// covered in the first minute; anything still uncovered is picked up on
    /// the next launch, because only missing sessions are ever sent.
    private static let backfillLimit = 25
    private var backfillStarted = false

    /// Distills recent sessions that predate the distiller, once per launch.
    /// Without this the layer starts empty for every existing user and the
    /// upgrade "feels" like nothing for weeks — the one thing a release of
    /// this feature is not allowed to feel like. Serial, oldest last, and
    /// quiet: every failure is one session's facts, never a broken start.
    func backfillDistill() async {
        guard !backfillStarted else { return }
        backfillStarted = true
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct MeetingRow: Decodable {
            let id: UUID
            let startedAt: Date
            let endedAt: Date

            enum CodingKeys: String, CodingKey {
                case id
                case startedAt = "started_at"
                case endedAt = "ended_at"
            }
        }
        do {
            // Coverage is the server's fact (`meetings.distilled_at`), so this
            // is one indexed question — never a walk over every concept row.
            let pending: [MeetingRow] = try await supabase
                .from("meetings")
                .select("id, started_at, ended_at")
                .is("deleted_at", value: nil)
                .is("distilled_at", value: nil)
                .lte("ended_at", value: Date().ISO8601Format())
                .order("started_at", ascending: false)
                .limit(Self.backfillLimit)
                .execute()
                .value
            guard !pending.isEmpty else { return }
            Log.ui.info("KnowledgeStore.backfill distilling \(pending.count) session(s)")
            for row in pending where row.endedAt > row.startedAt {
                guard !Task.isCancelled, Date() >= distillationSchedule.deferredUntil else { break }
                await distill(meetingID: row.id, skipCompleted: true)
            }
        } catch {
            Log.ui.debug("KnowledgeStore.backfill skipped: \(error.localizedDescription)")
        }
    }

    /// The recall card's "this replaces it": marks the concept superseded and
    /// records what the room just said as the claim's current version. Returns
    /// whether the correction landed, so the card can close only on truth.
    func supersede(conceptID: UUID, with body: String, meetingID: UUID?) async -> Bool {
        struct Params: Encodable {
            let p_concept: String
            let p_body: String
            let p_meeting: String?
        }
        do {
            _ = try await supabase
                .rpc(
                    "supersede_concept",
                    params: Params(
                        p_concept: conceptID.uuidString,
                        p_body: body,
                        p_meeting: meetingID?.uuidString
                    )
                )
                .execute()
            invalidateCache()
            Log.ui.info("KnowledgeStore.supersede concept=\(conceptID.uuidString)")
            return true
        } catch {
            Log.ui.error("KnowledgeStore.supersede failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether the index covers enough of a session's transcript to answer
    /// from retrieval alone. An interrupted index run (app quit, a batch that
    /// never landed) leaves a session with its opening minutes indexed and
    /// nothing else — retrieval then returns small talk for every question and
    /// the model reports the rest of the meeting as never discussed. Callers
    /// fall back to the transcript itself when this is false.
    /// The margin absorbs chunk-boundary drift: speaker names added after
    /// indexing change the `[Name]:` prefixes, so the same transcript can chunk
    /// slightly differently than it did at index time.
    func coversTranscript(meetingID: UUID, expectedChunks: Int) async -> Bool {
        guard expectedChunks > 0 else { return false }
        let indexed = await indexedChunkCount(meetingID: meetingID)
        return Double(indexed) >= Double(expectedChunks) * 0.85
    }

    private func indexedChunkCount(meetingID: UUID) async -> Int {
        #if DEBUG
            if DemoMode.isEnabled { return Int.max }
        #endif
        do {
            let response = try await supabase
                .from("session_embeddings")
                .select("chunk_idx", head: true, count: .exact)
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
            return response.count ?? 0
        } catch {
            Log.ui.error("KnowledgeStore.indexedChunkCount failed: \(error.localizedDescription)")
            // Unknown coverage reads as complete: a lookup blip shouldn't push
            // every long session onto the full-transcript path at once.
            return Int.max
        }
    }

    // MARK: - Background repair

    /// Set while a session is capturing. Repair shares the proxy with the live
    /// Whisper path, where a queued 429 costs a dropped chunk of the meeting the
    /// user is actually in — so it stands down until capture ends.
    var isCapturing = false

    /// Sessions repaired per run. Each one is ~30 sequential proxy calls plus
    /// the embeddings they bill, so this stays small and converges over
    /// launches, newest first. Users in a hurry have the Rebuild control in the
    /// sessions list.
    private static let repairBatchLimit = 3
    private static let repairInterval: TimeInterval = 6 * 3600
    private static let lastRepairKey = "knowledge.repair.lastRunAt"
    private static let clearedRepairKey = "knowledge.repair.cleared"

    private struct UnderIndexedSession: Decodable {
        let meetingID: UUID
        /// nil for sessions indexed before the proxy recorded a chunk total —
        /// those reach the shortlist on a duration heuristic, so the exact call
        /// happens here, against the transcript.
        let expectedChunks: Int?
        let chunkCount: Int

        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id"
            case expectedChunks = "expected_chunks"
            case chunkCount = "chunk_count"
        }
    }

    /// Re-indexes sessions the index has lost, without waiting for the user to
    /// open one. `SessionChatView` repairs the session being asked about, but
    /// corpus-wide retrieval has no such fallback: a session with no chunks
    /// doesn't exist for "Ask Nod", and nothing else would ever go back for it.
    ///
    /// Cost is bounded on both sides. The shortlist is one indexed aggregate in
    /// Postgres (`under_indexed_sessions`) rather than a walk over the user's
    /// transcripts, so a multi-year history costs the same as a new account;
    /// `transcript` is then read only for the handful it returns, and only a
    /// session that is genuinely short of chunks gets re-embedded — the SQL
    /// screen is deliberately coarse.
    func repairUnderIndexed(transcript: (UUID) async throws -> String) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        guard !isCapturing, dueForRepair else { return }
        var cleared = Self.clearedRepairs
        guard let candidates = await underIndexedSessions(excluding: cleared) else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastRepairKey)
        guard !candidates.isEmpty else { return }
        Log.ui.info("KnowledgeStore.repair candidates=\(candidates.count)")
        for candidate in candidates {
            guard !isCapturing else { return }
            do {
                let text = try await transcript(candidate.meetingID)
                let expected = candidate.expectedChunks ?? Self.chunk(text).count
                guard expected > 0, Double(candidate.chunkCount) < Double(expected) * 0.85 else {
                    // The heuristic shortlist flagged a session that is in fact
                    // covered. Remember it, or it reaches the front of every
                    // future shortlist and starves the ones that need work.
                    cleared.insert(candidate.meetingID)
                    Self.clearedRepairs = cleared
                    continue
                }
                Log.ui.info(
                    "KnowledgeStore.repair meeting=\(candidate.meetingID.uuidString) had=\(candidate.chunkCount) expected=\(expected)"
                )
                await index(meetingID: candidate.meetingID, transcript: text)
            } catch {
                Log.ui.error("KnowledgeStore.repair skipped \(candidate.meetingID.uuidString): \(error.localizedDescription)")
            }
        }
    }

    /// Sessions a previous run measured against their transcript and found
    /// fully covered — only ever heuristic shortlist entries, since an exact
    /// total can't produce a false positive. Repairing one writes it a real
    /// total, so this set stays small and stops growing.
    private static var clearedRepairs: Set<UUID> {
        get {
            Set((UserDefaults.standard.array(forKey: clearedRepairKey) as? [String] ?? []).compactMap(UUID.init))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: clearedRepairKey)
        }
    }

    private var dueForRepair: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastRepairKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.repairInterval
    }

    /// nil distinguishes "couldn't ask" from "nothing to repair" — a failed
    /// lookup must not stamp the throttle and skip the next six hours.
    private func underIndexedSessions(excluding cleared: Set<UUID>) async -> [UnderIndexedSession]? {
        struct Params: Encodable {
            let p_limit: Int
            let p_exclude: [String]?
        }
        do {
            return try await supabase
                .rpc(
                    "under_indexed_sessions",
                    params: Params(
                        p_limit: Self.repairBatchLimit,
                        p_exclude: cleared.isEmpty ? nil : cleared.map(\.uuidString)
                    )
                )
                .execute()
                .value
        } catch {
            Log.ui.error("KnowledgeStore.underIndexedSessions failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-indexes a batch of already-saved sessions (e.g. ones recorded before
    /// indexing existed, or under older chunking). `transcript` resolves each
    /// session's text; `progress` reports (done, total) for a UI bar. Failures
    /// per session are logged and skipped, never aborting the run.
    func reindex(
        _ meetings: [Meeting],
        transcript: (UUID) async throws -> String,
        progress: @MainActor (Int, Int) -> Void
    ) async {
        let total = meetings.count
        for (done, meeting) in meetings.enumerated() {
            do {
                let text = try await transcript(meeting.id)
                await index(meetingID: meeting.id, transcript: text)
            } catch {
                Log.ui.error("KnowledgeStore.reindex skipped \(meeting.id.uuidString): \(error.localizedDescription)")
            }
            progress(done + 1, total)
        }
    }

    /// Cosine-similarity floor for a chunk to count as relevant. Deliberately
    /// low — gte-small similarities are compressed, so this only removes the
    /// obvious-noise tail; the grounding prompt + shown sources do the rest.
    /// Tune against real retrieval data.
    static let minSimilarity: Double = 0.3

    // MARK: - Helpers

    /// Splits a transcript into ~`targetChunkChars` pieces on entry (line)
    /// boundaries, carrying one line of overlap into the next chunk so a
    /// thought split across a boundary keeps its context on both sides.
    static func chunk(_ transcript: String) -> [String] {
        let lines = transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return [] }

        var chunks: [String] = []
        var current: [String] = []
        var currentLen = 0

        for line in lines {
            if currentLen + line.count + 1 > targetChunkChars, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                // 1-line overlap for cross-boundary continuity.
                let carry = current.last.map { [$0] } ?? []
                current = carry
                currentLen = carry.reduce(0) { $0 + $1.count + 1 }
            }
            current.append(line)
            currentLen += line.count + 1
        }
        let tail = current.joined(separator: "\n")
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(tail)
        }
        return chunks
    }
}

struct DistillationSchedule {
    private var active: Set<UUID> = []
    private var failures: [UUID: Date] = [:]
    private(set) var deferredUntil = Date.distantPast

    mutating func begin(_ meetingID: UUID, now: Date = Date()) -> Bool {
        guard now >= deferredUntil, now >= (failures[meetingID] ?? .distantPast) else { return false }
        return active.insert(meetingID).inserted
    }

    mutating func finish(_ meetingID: UUID) {
        active.remove(meetingID)
    }

    mutating func succeeded(_ meetingID: UUID) {
        failures.removeValue(forKey: meetingID)
    }

    mutating func failed(_ meetingID: UUID, now: Date = Date()) {
        failures[meetingID] = now.addingTimeInterval(300)
    }

    mutating func rateLimited(for seconds: TimeInterval, now: Date = Date()) {
        deferredUntil = max(deferredUntil, now.addingTimeInterval(seconds))
    }
}
