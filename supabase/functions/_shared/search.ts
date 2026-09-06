import { MODELS } from "./models.ts";
import { adminClient } from "./supabase.ts";
import { isObject, json } from "./http.ts";
import { recordUsage } from "./usage.ts";
import { conceptsForSearch } from "./knowledge.ts";

// `Supabase.ai` is an ambient global provided by the Edge Function runtime —
// declare it so TypeScript doesn't choke on the gte-small embedding session.
declare const Supabase: {
    ai: { Session: new (model: string) => { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } };
};

// Semantic index and search over meeting transcripts. Embeddings run inside the
// Edge runtime (gte-small, no upstream bill), so an `embed` usage row is about
// volume and quota, not dollars.

// gte-small produces 384-dim normalised embeddings — matches the
// `vector(384)` column in `session_embeddings`.
const EMBEDDING_MODEL = MODELS.embedding.default;

// Upper bound on how many chunks a single search may pull. The client asks for
// 8; the cap stops a crafted `match_count` from turning the vector scan into a
// whole-table read.
const MAX_SEARCH_MATCHES = 50;

let embeddingSession: { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } | null = null;
function embedder() {
    if (!embeddingSession) embeddingSession = new Supabase.ai.Session(EMBEDDING_MODEL);
    return embeddingSession;
}
export async function embedText(text: string): Promise<number[]> {
    return await embedder().run(text, { mean_pool: true, normalize: true });
}

export async function handleIndex(payload: unknown, userId: string): Promise<Response> {
    if (!isObject(payload) || typeof payload.meeting_id !== "string" || !Array.isArray(payload.chunks)) {
        return json({ error: "index requires { meeting_id, chunks[] }" }, 400);
    }
    const meetingId = payload.meeting_id;
    const chunks = (payload.chunks as unknown[]).filter((c): c is string => typeof c === "string" && c.trim().length > 0);
    if (chunks.length === 0) return json({ indexed: 0 }, 200);
    // The client batches a session's chunks across several index calls so a
    // single invocation never embeds enough long chunks to exceed the worker
    // CPU budget. `base_idx` is this batch's offset into the session's chunk
    // list; `total` is the session's full chunk count (used to prune stale
    // rows). Both default to the legacy single-call shape.
    const baseIdx = typeof payload.base_idx === "number" ? Math.max(0, Math.floor(payload.base_idx)) : 0;
    const total = typeof payload.total === "number" ? Math.floor(payload.total) : baseIdx + chunks.length;

    const admin = adminClient();

    // Denormalize the session's start time + kind onto each chunk so search
    // can scope by them without a join.
    const { data: meeting } = await admin
        .from("meetings")
        .select("started_at, kind, user_id")
        .eq("id", meetingId)
        .maybeSingle();
    // The session must exist and belong to the caller. Skipping this when the
    // lookup misses would waste embeddings on rows the FK rejects (non-existent
    // id) or write null started_at/kind metadata (soft-deleted id) that later
    // time/kind-scoped retrieval can't filter.
    if (!meeting) {
        return json({ error: "meeting not found" }, 404);
    }
    if (meeting.user_id !== userId) {
        return json({ error: "meeting does not belong to user" }, 403);
    }
    const startedAt = meeting.started_at ?? null;
    const kind = meeting.kind ?? null;

    const rows: { meeting_id: string; user_id: string; chunk_idx: number; content: string; embedding: number[]; started_at: string | null; kind: string | null }[] = [];
    for (let i = 0; i < chunks.length; i++) {
        const chunkIdx = baseIdx + i;
        try {
            const embedding = await embedText(chunks[i]);
            rows.push({ meeting_id: meetingId, user_id: userId, chunk_idx: chunkIdx, content: chunks[i], embedding, started_at: startedAt, kind });
        } catch (err) {
            console.error(`embed chunk ${chunkIdx} failed: ${err}`);
        }
    }
    if (rows.length === 0) return json({ indexed: 0, error: "all chunks failed to embed" }, 500);

    const { error } = await admin.from("session_embeddings").upsert(rows, { onConflict: "meeting_id,chunk_idx" });
    if (error) {
        console.error(`index upsert failed: ${error.message}`);
        return json({ indexed: 0, error: error.message }, 500);
    }
    // A re-index that produces fewer chunks than before leaves stale rows at
    // chunk_idx >= total. Prune them so old content can't resurface in search.
    // `total` is constant across a session's batches, so pruning each batch is
    // safe and idempotent.
    const { error: pruneError } = await admin
        .from("session_embeddings")
        .delete()
        .eq("meeting_id", meetingId)
        .gte("chunk_idx", total);
    if (pruneError) {
        console.warn(`index prune failed (non-fatal): ${pruneError.message}`);
    }
    // Record how many chunks the session *should* have, so a later sweep can
    // spot a run that died part-way (`under_indexed_sessions`) by comparing a
    // count against this — no transcript read, no guessing from duration.
    // Written on every batch, unconditionally: batch 0 is not guaranteed to be
    // the one that lands, and a session is indexed once, so re-writing the same
    // small int ~30 times costs less than a filter that could silently never
    // match.
    const { error: totalError } = await admin
        .from("meetings")
        .update({ indexed_chunk_total: total })
        .eq("id", meetingId);
    if (totalError) {
        console.warn(`index total write failed (non-fatal): ${totalError.message}`);
    }
    await recordEmbedUsage(userId, 200);
    console.log(`index user=${userId} meeting=${meetingId} chunks=${rows.length}`);
    return json({ indexed: rows.length }, 200);
}

// Cross-session search: embed the query, then rank the user's chunks by cosine
// similarity via the match RPC. The RPC is called with the service role, which
// bypasses RLS, so the `p_user_id` predicate (set to the verified JWT user) is
// the row-scoping boundary — not RLS.
export async function handleSearch(payload: unknown, userId: string): Promise<Response> {
    if (!isObject(payload) || typeof payload.query !== "string") {
        return json({ error: "search requires { query }" }, 400);
    }
    const query = payload.query.trim();
    if (query.length === 0) return json({ matches: [] }, 200);
    // HyDE: when the client sends a hypothetical answer, embed THAT (it lives
    // in the same space as transcript chunks) while keeping `query` for entity
    // matching + scoping. Absent → embed the raw query (legacy behavior).
    const hyde = typeof payload.embed_text === "string" ? payload.embed_text.trim() : "";
    const textToEmbed = hyde.length > 0 ? hyde : query;
    const requestedCount = typeof payload.match_count === "number" ? payload.match_count : 8;
    const matchCount = Math.min(Math.max(1, Math.floor(requestedCount)), MAX_SEARCH_MATCHES);
    const meetingId = typeof payload.meeting_id === "string" ? payload.meeting_id : null;
    // Label scope: constrain the cross-session search to a set of sessions.
    const meetingIds = Array.isArray(payload.meeting_ids)
        ? payload.meeting_ids.filter((id): id is string => typeof id === "string")
        : null;

    let embedding: number[];
    try {
        embedding = await embedText(textToEmbed);
    } catch (err) {
        console.error(`search embed failed: ${err}`);
        return json({ matches: [], error: "embedding failed" }, 500);
    }
    await recordEmbedUsage(userId, 200);

    const admin = adminClient();

    // Stage one, cross-session only: current concepts for the entities the
    // question names. Started here so it overlaps the chunk match instead of
    // adding a round trip; dark until `KNOWLEDGE_READ_ENABLED` says retrieval
    // may read what distillation writes. An old client ignores the extra field.
    const conceptStage = meetingId
        ? Promise.resolve([])
        : conceptsForSearch(admin, userId, query, embedding);

    // Over-fetch so the entity boost below has headroom to re-rank.
    const { data, error } = await admin.rpc("match_session_chunks", {
        query_embedding: embedding,
        match_count: meetingId ? matchCount : matchCount * 2,
        p_user_id: userId,
        p_meeting_id: meetingId,
        p_meeting_ids: meetingIds,
    });
    if (error) {
        console.error(`search rpc failed: ${error.message}`);
        return json({ matches: [], error: error.message }, 500);
    }

    interface Match { meeting_id: string; content: string; similarity: number }
    let matches = (data ?? []) as Match[];

    // Hybrid boost (cross-session only): lift chunks from sessions whose
    // extracted entity is named in the query, so "what did Sarah say about X"
    // surfaces Sarah's sessions even when pure vector rank misses them.
    //
    // The boost orders, it does not score. It used to be added into
    // `similarity` itself, so a named-person match reported 0.1 more than it
    // measured — and the client thresholds on that number to decide what may
    // ground and cite an answer. Same reasoning as the recency prior in
    // `match_session_chunks`, which also ranks with a bonus and returns the raw
    // cosine.
    if (!meetingId && matches.length > 0) {
        try {
            const { data: entRows } = await admin.rpc("meetings_matching_entities", {
                p_user_id: userId,
                p_query: query,
            });
            const boosted = new Set((entRows ?? []).map((r: { meeting_id: string }) => r.meeting_id));
            if (boosted.size > 0) {
                matches = matches
                    .map((m) => ({ match: m, rank: boosted.has(m.meeting_id) ? m.similarity + 0.1 : m.similarity }))
                    .sort((a, b) => b.rank - a.rank)
                    .map(({ match }) => match);
            }
        } catch (err) {
            console.warn(`entity boost skipped: ${err}`);
        }
    }

    const concepts = await conceptStage;
    return json({ matches: matches.slice(0, matchCount), concepts }, 200);
}

// gte-small runs inside the Edge runtime (no upstream bill), so we log one
// `embed` event per index/search call for volume + quota accounting (#17),
// not dollar cost. Best-effort: a logging failure never blocks the caller.
async function recordEmbedUsage(userId: string, status: number): Promise<void> {
    try {
        await recordUsage({ user_id: userId, kind: "embed", model: EMBEDDING_MODEL, status });
    } catch (err) {
        console.warn(`embed usage record skipped: ${err}`);
    }
}

// Which plan feature a search requires, by scope: a single-meeting question is
// Starter-tier (`ask_single_meeting`); a label-scoped question and a
// cross-session question are Pro (`label_scoping` / `ask_across_meetings`).
export function requiredSearchFeature(payload: unknown): string {
    if (isObject(payload)) {
        if (Array.isArray(payload.meeting_ids) && payload.meeting_ids.length > 0) return "label_scoping";
        if (typeof payload.meeting_id === "string" && payload.meeting_id.length > 0) return "ask_single_meeting";
    }
    return "ask_across_meetings";
}

