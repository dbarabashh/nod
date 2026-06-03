// LLM proxy — server-side gateway for OpenRouter chat + Whisper transcription.
//
// Why this exists (issue #11):
// - Removes the OpenRouter API key from the client binary (it stays in
//   Supabase secrets, only the Edge Function sees it).
// - Authenticates every request with the user's Supabase JWT — gives us a
//   place to enforce per-user quota (issue #17) later.
// - Single network hop for both chat completions and Whisper transcription.
// - Captures upstream usage into `public.usage_events` so we can price the
//   product against real costs and enforce per-user quotas (#17).
//
// Request shape (POST /functions/v1/llm-proxy):
//   Authorization: Bearer <supabase-access-token>
//   Content-Type:  application/json
//   Body:          { "kind": "chat" | "transcribe", "payload": { …upstream… } }
//
// The `payload` is forwarded to OpenRouter under the matching endpoint. For
// chat, we inject `usage: { include: true }` so the response carries cost in
// dollars — the client never sees this field, it just lands in the DB.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

// `Supabase.ai` is an ambient global provided by the Edge Function runtime —
// declare it so TypeScript doesn't choke on the gte-small embedding session.
declare const Supabase: {
    ai: { Session: new (model: string) => { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } };
};

const OPENROUTER_API_KEY        = Deno.env.get("OPENROUTER_API_KEY");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const CHAT_TIMEOUT_MS      = 30_000;
const TRANSCRIBE_TIMEOUT_MS = 60_000;

const OPENROUTER_CHAT_URL       = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TRANSCRIBE_URL = "https://openrouter.ai/api/v1/audio/transcriptions";

// gte-small produces 384-dim normalised embeddings — matches the
// `vector(384)` column in `session_embeddings`.
const EMBEDDING_MODEL = "gte-small";

// Upper bound on how many chunks a single search may pull. The client asks for
// 8; the cap stops a crafted `match_count` from turning the vector scan into a
// whole-table read.
const MAX_SEARCH_MATCHES = 50;

let embeddingSession: { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } | null = null;
function embedder() {
    if (!embeddingSession) embeddingSession = new Supabase.ai.Session(EMBEDDING_MODEL);
    return embeddingSession;
}
async function embedText(text: string): Promise<number[]> {
    return await embedder().run(text, { mean_pool: true, normalize: true });
}

// 16 kHz × 16-bit × mono == 32_000 bytes per second of audio. The client
// always normalises to this format before posting (see WhisperTranscriber),
// so we can recover the duration from the base64-decoded byte count + the WAV
// header (44 bytes). Off by ≤0.1% — fine for cost accounting.
const PCM_BYTES_PER_SECOND = 32_000;
const WAV_HEADER_BYTES     = 44;

type Kind = "chat" | "transcribe" | "index" | "search";

interface ProxyRequest {
    kind: Kind;
    payload: unknown;
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
        return json({ error: "Method Not Allowed" }, 405);
    }

    if (!OPENROUTER_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: OPENROUTER_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Unauthenticated" }, 401);

    const token = authHeader.replace(/^Bearer\s+/i, "");
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
        console.warn(`JWT rejected: ${userError?.message ?? "no user"}`);
        return json({ error: "Unauthenticated" }, 401);
    }

    let body: ProxyRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }

    if (!body.kind || body.payload === undefined) {
        return json({ error: "Missing 'kind' or 'payload'" }, 400);
    }

    switch (body.kind) {
        case "chat":
            return forwardChat(body.payload, user.id);
        case "transcribe":
            return forwardTranscribe(body.payload, user.id);
        case "index":
            return handleIndex(body.payload, user.id);
        case "search":
            return handleSearch(body.payload, user.id);
        default:
            return json({ error: `Unknown kind: ${body.kind}` }, 400);
    }
});

async function forwardChat(payload: unknown, userId: string): Promise<Response> {
    // Inject `usage: { include: true }` so OpenRouter returns `usage.cost`
    // (USD) on every response. The Swift client decodes only `choices`, so
    // adding this field is transparent client-side.
    const enriched = isObject(payload) ? { ...payload, usage: { include: true } } : payload;
    const model = isObject(payload) && typeof payload.model === "string" ? payload.model : "unknown";

    const { status, text } = await callOpenRouter(OPENROUTER_CHAT_URL, enriched, CHAT_TIMEOUT_MS, userId, "chat");

    // Best-effort: parse usage from the response. Never block the user on a
    // logging failure — if anything throws, swallow it and serve the body.
    try {
        const parsed = JSON.parse(text);
        await recordUsage({
            user_id: userId,
            kind: "chat",
            model,
            status,
            prompt_tokens:     parsed?.usage?.prompt_tokens     ?? null,
            completion_tokens: parsed?.usage?.completion_tokens ?? null,
            generation_id:     parsed?.id                       ?? null,
            cost_usd:          parsed?.usage?.cost              ?? null,
        });
    } catch (err) {
        console.warn(`chat usage record skipped: ${err}`);
    }

    return new Response(text, {
        status,
        headers: { "Content-Type": "application/json" },
    });
}

async function forwardTranscribe(payload: unknown, userId: string): Promise<Response> {
    const model = isObject(payload) && typeof payload.model === "string" ? payload.model : "unknown";
    const audioSeconds = audioSecondsFromPayload(payload);

    const { status, text } = await callOpenRouter(OPENROUTER_TRANSCRIBE_URL, payload, TRANSCRIBE_TIMEOUT_MS, userId, "transcribe");

    try {
        await recordUsage({
            user_id: userId,
            kind: "transcribe",
            model,
            status,
            audio_seconds: audioSeconds,
            cost_usd: null, // OpenRouter doesn't return usage for audio; reconcile via /generation later.
        });
    } catch (err) {
        console.warn(`transcribe usage record skipped: ${err}`);
    }

    return new Response(text, {
        status,
        headers: { "Content-Type": "application/json" },
    });
}

// Index a session's transcript chunks: embed each with gte-small and upsert
// into `session_embeddings` with the service role. Doing the write here (not
// on the client) keeps vectors as native arrays — no text→vector cast guesswork.
async function handleIndex(payload: unknown, userId: string): Promise<Response> {
    if (!isObject(payload) || typeof payload.meeting_id !== "string" || !Array.isArray(payload.chunks)) {
        return json({ error: "index requires { meeting_id, chunks[] }" }, 400);
    }
    const meetingId = payload.meeting_id;
    const chunks = (payload.chunks as unknown[]).filter((c): c is string => typeof c === "string" && c.trim().length > 0);
    if (chunks.length === 0) return json({ indexed: 0 }, 200);

    const admin = createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!, {
        auth: { persistSession: false, autoRefreshToken: false },
    });

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
        try {
            const embedding = await embedText(chunks[i]);
            rows.push({ meeting_id: meetingId, user_id: userId, chunk_idx: i, content: chunks[i], embedding, started_at: startedAt, kind });
        } catch (err) {
            console.error(`embed chunk ${i} failed: ${err}`);
        }
    }
    if (rows.length === 0) return json({ indexed: 0, error: "all chunks failed to embed" }, 500);

    const { error } = await admin.from("session_embeddings").upsert(rows, { onConflict: "meeting_id,chunk_idx" });
    if (error) {
        console.error(`index upsert failed: ${error.message}`);
        return json({ indexed: 0, error: error.message }, 500);
    }
    // chunk_idx is the 0-based position in the input array, so a re-index that
    // produces fewer chunks than before leaves stale rows at chunk_idx >=
    // chunks.length. Prune them so old content can't resurface in search.
    const { error: pruneError } = await admin
        .from("session_embeddings")
        .delete()
        .eq("meeting_id", meetingId)
        .gte("chunk_idx", chunks.length);
    if (pruneError) {
        console.warn(`index prune failed (non-fatal): ${pruneError.message}`);
    }
    await recordEmbedUsage(userId, 200);
    console.log(`index user=${userId} meeting=${meetingId} chunks=${rows.length}`);
    return json({ indexed: rows.length }, 200);
}

// Cross-session search: embed the query, then rank the user's chunks by cosine
// similarity via the match RPC. The RPC is called with the service role, which
// bypasses RLS, so the `p_user_id` predicate (set to the verified JWT user) is
// the row-scoping boundary — not RLS.
async function handleSearch(payload: unknown, userId: string): Promise<Response> {
    if (!isObject(payload) || typeof payload.query !== "string") {
        return json({ error: "search requires { query }" }, 400);
    }
    const query = payload.query.trim();
    if (query.length === 0) return json({ matches: [] }, 200);
    const requestedCount = typeof payload.match_count === "number" ? payload.match_count : 8;
    const matchCount = Math.min(Math.max(1, Math.floor(requestedCount)), MAX_SEARCH_MATCHES);
    const meetingId = typeof payload.meeting_id === "string" ? payload.meeting_id : null;

    let embedding: number[];
    try {
        embedding = await embedText(query);
    } catch (err) {
        console.error(`search embed failed: ${err}`);
        return json({ matches: [], error: "embedding failed" }, 500);
    }
    await recordEmbedUsage(userId, 200);

    const admin = createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!, {
        auth: { persistSession: false, autoRefreshToken: false },
    });

    // Over-fetch so the entity boost below has headroom to re-rank.
    const { data, error } = await admin.rpc("match_session_chunks", {
        query_embedding: embedding,
        match_count: meetingId ? matchCount : matchCount * 2,
        p_user_id: userId,
        p_meeting_id: meetingId,
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
    if (!meetingId && matches.length > 0) {
        try {
            const { data: entRows } = await admin.rpc("meetings_matching_entities", {
                p_user_id: userId,
                p_query: query,
            });
            const boosted = new Set((entRows ?? []).map((r: { meeting_id: string }) => r.meeting_id));
            if (boosted.size > 0) {
                matches = matches
                    .map((m) => boosted.has(m.meeting_id) ? { ...m, similarity: m.similarity + 0.1 } : m)
                    .sort((a, b) => b.similarity - a.similarity);
            }
        } catch (err) {
            console.warn(`entity boost skipped: ${err}`);
        }
    }

    return json({ matches: matches.slice(0, matchCount) }, 200);
}

interface CallResult { status: number; text: string }

async function callOpenRouter(
    url: string,
    payload: unknown,
    timeoutMs: number,
    userId: string,
    label: string,
): Promise<CallResult> {
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
        const upstream = await fetch(url, {
            method: "POST",
            headers: {
                "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                "X-Title": "Nod",
            },
            body: JSON.stringify(payload),
            signal: controller.signal,
        });

        const text = await upstream.text();
        const dt = Date.now() - started;
        console.log(`${label} user=${userId} status=${upstream.status} dt=${dt}ms bytes=${text.length}`);

        return { status: upstream.status, text };
    } catch (error) {
        const dt = Date.now() - started;
        if (error instanceof DOMException && error.name === "AbortError") {
            console.error(`${label} user=${userId} timeout after ${dt}ms`);
            return { status: 504, text: JSON.stringify({ error: `Upstream timeout (${timeoutMs}ms)` }) };
        }
        console.error(`${label} user=${userId} upstream error: ${error}`);
        return { status: 502, text: JSON.stringify({ error: "Upstream request failed" }) };
    } finally {
        clearTimeout(timer);
    }
}

interface UsageRow {
    user_id: string;
    kind: "chat" | "transcribe" | "embed";
    model: string;
    status: number;
    prompt_tokens?: number | null;
    completion_tokens?: number | null;
    generation_id?: string | null;
    audio_seconds?: number | null;
    cost_usd?: number | null;
}

async function recordUsage(row: UsageRow): Promise<void> {
    // Service role bypasses RLS — required, since the table forbids client
    // inserts. We construct a dedicated client per request rather than reusing
    // the JWT-scoped one above.
    const admin = createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!, {
        auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await admin.from("usage_events").insert(row);
    if (error) {
        console.warn(`usage_events insert failed: ${error.message}`);
    }
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

// Reverse the client's encoding: payload.input_audio.data is a base64 WAV.
// Decode → strip 44-byte header → divide by 32 kB/s. Returns null if the
// shape doesn't match (defensive; the Swift client always sends WAV).
function audioSecondsFromPayload(payload: unknown): number | null {
    if (!isObject(payload)) return null;
    const inputAudio = payload.input_audio;
    if (!isObject(inputAudio) || typeof inputAudio.data !== "string") return null;
    try {
        // base64 length × 3/4 — we only need the byte count, not the bytes.
        const b64 = inputAudio.data;
        const padding = (b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0);
        const byteCount = Math.floor((b64.length * 3) / 4) - padding;
        const pcmBytes = Math.max(0, byteCount - WAV_HEADER_BYTES);
        return Math.round((pcmBytes / PCM_BYTES_PER_SECOND) * 1000) / 1000;
    } catch {
        return null;
    }
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(body: unknown, status: number): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}
