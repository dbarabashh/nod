import Combine
import Foundation

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

    /// ~1200 chars ≈ a few minutes of dialogue — small enough to be a precise
    /// retrieval unit, large enough to carry context.
    private static let targetChunkChars = 1200

    init(llm: LLMProxyClient) {
        self.llm = llm
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

    private var cache: [CacheKey: [RetrievedChunk]] = [:]
    private var cacheOrder: [CacheKey] = []

    /// Small enough to stay bounded, big enough to cover a typing session and a
    /// few chat turns. Results only go stale when the corpus changes, which is
    /// exactly when `index`/`reindex` clear it.
    private static let cacheLimit = 60

    private func store(_ chunks: [RetrievedChunk], for key: CacheKey) {
        cache[key] = chunks
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

    private func invalidateCache() {
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
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
                return DemoData.knowledgeChunks(
                    query: trimmed,
                    matchCount: matchCount,
                    meetingID: meetingID,
                    meetingIDs: meetingIDs
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
            let filtered = meetingID == nil
                ? results.filter { $0.similarity >= Self.minSimilarity }
                : results
            store(filtered, for: cacheKey)
            return filtered
        } catch LLMProxyClient.ClientError.entitlementRequired {
            // Expected gated state, not a failure: on a lapsed plan the proxy
            // 403s `search` and the client has already surfaced the paywall.
            // Fail soft to [] — the chat call that follows enforces entitlement
            // again and is the real gate, so don't log this as an error.
            Log.ui.info("KnowledgeStore.search gated (entitlement) — returning no chunks")
            return []
        } catch {
            Log.ui.error("KnowledgeStore.search failed: \(error.localizedDescription)")
            return []
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
