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
    private let llm: OpenRouterClient

    /// ~1200 chars ≈ a few minutes of dialogue — small enough to be a precise
    /// retrieval unit, large enough to carry context.
    private static let targetChunkChars = 1200

    init(llm: OpenRouterClient) {
        self.llm = llm
    }

    /// Indexes the session's transcript for cross-session search. The proxy
    /// embeds each chunk (gte-small) and stores the vectors. Best-effort:
    /// a failure just means this session won't surface in search, never a
    /// broken save.
    func index(meetingID: UUID, transcript: String) async {
        let chunks = Self.chunk(transcript)
        guard !chunks.isEmpty else { return }
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
    func search(query: String, matchCount: Int = 8, meetingID: UUID? = nil, meetingIDs: [UUID]? = nil) async -> [RetrievedChunk] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let results = try await llm.searchKnowledge(query: trimmed, matchCount: matchCount, meetingID: meetingID, meetingIDs: meetingIDs)
            guard meetingID == nil else { return results }
            return results.filter { $0.similarity >= Self.minSimilarity }
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
