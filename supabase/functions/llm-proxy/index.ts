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

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";

// `Supabase.ai` is an ambient global provided by the Edge Function runtime —
// declare it so TypeScript doesn't choke on the gte-small embedding session.
declare const Supabase: {
    ai: { Session: new (model: string) => { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<number[]> } };
};

const OPENROUTER_API_KEY        = Deno.env.get("OPENROUTER_API_KEY");
// STT providers (issue: direct-provider STT route). Both are OpenAI-compatible
// multipart endpoints. The cutover is env-gated: with no GROQ_API_KEY set, the
// transcribe path stays on the legacy OpenRouter base64-JSON route, so deploying
// this function is a no-op until the secret lands. Once GROQ_API_KEY is set,
// Groq serves primary with OpenAI as the transient-failure fallback (Groq has a
// real rate-limit/availability ceiling at peak), and OpenRouter as last resort.
const GROQ_API_KEY              = Deno.env.get("GROQ_API_KEY");
const OPENAI_API_KEY            = Deno.env.get("OPENAI_API_KEY");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const CHAT_TIMEOUT_MS      = 30_000;
const TRANSCRIBE_TIMEOUT_MS = 60_000;

// A device holds its account slot for this long without making a call. During
// a meeting the steady transcribe traffic keeps it fresh; once the app quits
// or sits idle past this window the slot frees so another device can claim it
// (the "timeout" half of the single-device lock — see claim_device migration).
const DEVICE_ACTIVE_TTL_SECONDS = 900;

const OPENROUTER_CHAT_URL       = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TRANSCRIBE_URL = "https://openrouter.ai/api/v1/audio/transcriptions";
const GROQ_TRANSCRIBE_URL       = "https://api.groq.com/openai/v1/audio/transcriptions";
const OPENAI_TRANSCRIBE_URL     = "https://api.openai.com/v1/audio/transcriptions";

// Startup diagnostic: prints once per cold start which STT provider keys the
// function can actually see. `set`/`MISSING` only — never the value. If this
// logs `groq=MISSING` while the dashboard shows a GROQ_API_KEY secret, the name
// doesn't match what the code reads (Deno.env.get("GROQ_API_KEY")).
console.log(`[stt] provider keys: groq=${GROQ_API_KEY ? "set" : "MISSING"} openai=${OPENAI_API_KEY ? "set" : "MISSING"} openrouter=${OPENROUTER_API_KEY ? "set" : "MISSING"}`);

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

type Kind = "chat" | "transcribe" | "index" | "search" | "device_claim" | "device_release";

interface ProxyRequest {
    kind: Kind;
    payload: unknown;
}

// `app_config.minimum_build`, cached per warm instance so the gate doesn't add
// a DB round-trip to every proxy call. 0 (fail-open) when the row can't be read.
let cachedMinBuild: { value: number; at: number } | null = null;
const MIN_BUILD_TTL_MS = 60_000;

async function minimumBuild(admin: ReturnType<typeof adminClient>): Promise<number> {
    const now = Date.now();
    if (cachedMinBuild && now - cachedMinBuild.at < MIN_BUILD_TTL_MS) return cachedMinBuild.value;
    const { data, error } = await admin
        .from("app_config")
        .select("minimum_build")
        .eq("singleton", true)
        .single();
    const value = (!error && data && typeof data.minimum_build === "number") ? data.minimum_build : 0;
    cachedMinBuild = { value, at: now };
    return value;
}

// Server-side entitlement gate (#17). Client-side feature gates are UX; this
// is the enforcement, at the only place a patched client can't skip. Resolved
// via `resolve_entitlement` (SECURITY DEFINER, service-role only) and cached
// per warm instance: steady transcribe traffic (~12 calls/min in a meeting)
// costs one DB round-trip per user per TTL, not per call. The cached
// hours_used therefore lags up to the TTL — fine, the cap is soft anyway.
interface Entitlement {
    plan: string;
    status: string;
    features: string[];
    hours_used: number;
    hours_limit: number;
}

const ENTITLEMENT_TTL_MS = 60_000;
// Sweep expired entries once the map crosses this size, so a warm instance
// serving many one-shot users doesn't accumulate entries unbounded (each is
// only TTL-checked on read, never otherwise removed).
const ENTITLEMENT_CACHE_MAX = 1_000;
const entitlementCache = new Map<string, { ent: Entitlement; at: number }>();

// Kinds exempt from the entitlement gate. Everything else is gated by default
// (see the gate below) so a new billable kind can't be added without one.
const UNGATED_KINDS = new Set(["device_claim", "device_release"]);

async function entitlementFor(admin: ReturnType<typeof adminClient>, userId: string): Promise<Entitlement | null> {
    const cached = entitlementCache.get(userId);
    const now = Date.now();
    if (cached) {
        if (now - cached.at < ENTITLEMENT_TTL_MS) return cached.ent;
        entitlementCache.delete(userId);
    }
    if (entitlementCache.size > ENTITLEMENT_CACHE_MAX) {
        for (const [k, v] of entitlementCache) {
            if (now - v.at >= ENTITLEMENT_TTL_MS) entitlementCache.delete(k);
        }
    }
    const { data, error } = await admin.rpc("resolve_entitlement", { p_user_id: userId });
    if (error || !isObject(data)) {
        console.warn(`entitlement lookup failed (fail-open): ${error?.message ?? "unexpected shape"}`);
        return null;
    }
    const ent: Entitlement = {
        plan: typeof data.plan === "string" ? data.plan : "none",
        status: typeof data.status === "string" ? data.status : "none",
        features: Array.isArray(data.features) ? data.features.filter((f): f is string => typeof f === "string") : [],
        hours_used: typeof data.hours_used === "number" ? data.hours_used : 0,
        hours_limit: typeof data.hours_limit === "number" ? data.hours_limit : 0,
    };
    entitlementCache.set(userId, { ent, at: now });
    return ent;
}

// Stamp the client's build/version onto its profile row — version visibility
// without an analytics SDK. Best-effort: a logging failure must never block
// the LLM call. `update` (not upsert) so we never create empty profile rows.
//
// Only write when something actually changed: a newer build, or a last_seen_at
// that's gone stale (heartbeat throttled to once a day). Without this gate the
// proxy rewrote an identical row on every call — hundreds of dead tuples/day on
// an 11-row table, pure autovacuum churn for no new information.
const HEARTBEAT_THROTTLE_MS = 24 * 60 * 60 * 1000;
async function stampClientVersion(admin: ReturnType<typeof adminClient>, userId: string, req: Request): Promise<void> {
    const build = parseInt(req.headers.get("x-app-build") ?? "", 10);
    if (!Number.isFinite(build)) return;
    const staleBefore = new Date(Date.now() - HEARTBEAT_THROTTLE_MS).toISOString();
    await admin.from("profiles").update({
        app_build: build,
        app_version: req.headers.get("x-app-version"),
        os_version: req.headers.get("x-os-version"),
        last_seen_at: new Date().toISOString(),
    })
        .eq("user_id", userId)
        .or(`app_build.is.null,app_build.neq.${build},last_seen_at.is.null,last_seen_at.lt.${staleBefore}`);
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
        return json({ error: "Method Not Allowed" }, 405);
    }

    if (!OPENROUTER_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: OPENROUTER_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    // Version gate + stamp. The gate (426) is the backstop for a stale client
    // that slipped past the launch check; the stamp records the build for
    // support visibility. Both fail open — a config/stamp error never blocks
    // a legitimate call.
    const admin = adminClient();
    const appBuild = parseInt(req.headers.get("x-app-build") ?? "", 10) || 0;
    const minBuild = await minimumBuild(admin);
    if (appBuild < minBuild) {
        return json({ error: "update_required", minimum_build: minBuild }, 426);
    }
    try {
        await stampClientVersion(admin, user.id, req);
    } catch (err) {
        console.warn(`version stamp skipped: ${err}`);
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

    // Single-device lock. `x-device-id` is the client's hardware UUID;
    // `x-device-name` is percent-encoded (machine names aren't ASCII-safe).
    const deviceId = req.headers.get("x-device-id");
    const deviceName = decodeDeviceName(req.headers.get("x-device-name"));

    // Explicit sign-out: free this device's slot so the user can sign in
    // elsewhere immediately, without waiting for the TTL to expire.
    if (body.kind === "device_release") {
        if (deviceId) {
            const { error } = await admin
                .from("user_devices")
                .delete()
                .eq("user_id", user.id)
                .eq("device_id", deviceId);
            if (error) console.warn(`device_release failed: ${error.message}`);
        }
        return json({ ok: true }, 200);
    }

    // Enforce on every other call — the proxy is the chokepoint, so a device
    // that loses the lock stops working regardless of client-side checks. A
    // refused device gets 409 device_conflict and the client signs out. Fail
    // open on any DB error: a lookup hiccup must never lock a user out of
    // their own account.
    if (deviceId) {
        try {
            const { data: allowed, error } = await admin.rpc("claim_device", {
                p_user_id: user.id,
                p_device_id: deviceId,
                p_device_name: deviceName,
                p_platform: "macos",
                p_ttl_seconds: DEVICE_ACTIVE_TTL_SECONDS,
            });
            if (error) {
                console.warn(`claim_device error (fail-open): ${error.message}`);
            } else if (allowed === false) {
                // 409 Conflict — the client keys off the status (not the body)
                // to detect the single-device lock and sign out.
                return json({ error: "device_conflict" }, 409);
            }
        } catch (err) {
            console.warn(`device enforcement skipped (fail-open): ${err}`);
        }
    }

    // Entitlement gate — deny by default on a lapsed plan (expired trial,
    // canceled sub, no subscription), with ONE exemption: `transcribe`. Live
    // audio is irreplaceable, so a meeting that's mid-recording when the plan
    // lapses still captures its transcript to the end; everything else (`chat`
    // recap/Ask, `index`, `search`) is blocked. The end-of-meeting summary (a
    // `chat` call) is therefore gated too, but it regenerates from the saved
    // transcript after the user renews — the recording itself is never lost.
    // Blocking `transcribe` for a NEW meeting is the client start-gate's job
    // (it checks isActive before recording); the proxy can't tell a new meeting
    // from a continued one, since both are just transcribe calls.
    //
    // `search` is additionally gated on the SPECIFIC plan feature its scope
    // maps to (a Starter user can ask within one meeting but not across all).
    // The hour cap stays soft (an over-cap call is still served; remaining
    // hours surface via x-nod-hours-* headers). Fail open on lookup errors: a
    // DB hiccup must never cut a live meeting.
    let entitlement: Entitlement | null = null;
    if (!UNGATED_KINDS.has(body.kind)) {
        entitlement = await entitlementFor(admin, user.id);
        const lapsed = entitlement && entitlement.status !== "trialing" && entitlement.status !== "active";
        if (lapsed && body.kind !== "transcribe") {
            return json({ error: "entitlement_required", status: entitlement!.status, plan: entitlement!.plan }, 403);
        }
        if (body.kind === "search" && entitlement) {
            const required = requiredSearchFeature(body.payload);
            if (!entitlement.features.includes(required)) {
                return json({ error: "feature_required", feature: required, plan: entitlement.plan }, 403);
            }
        }
    }

    switch (body.kind) {
        case "device_claim":
            // Reaching here means the device passed the lock above.
            return json({ ok: true }, 200);
        case "chat":
            return forwardChat(body.payload, user.id);
        case "transcribe":
            return forwardTranscribe(body.payload, user.id, entitlement, admin);
        case "index":
            return handleIndex(body.payload, user.id);
        case "search":
            return handleSearch(body.payload, user.id);
        default:
            return json({ error: `Unknown kind: ${body.kind}` }, 400);
    }
});

// Providers with an explicit prompt-cache API (a cache_control breakpoint on a
// content block). OpenAI caches automatically and rejects the unknown field, so
// it's excluded — its prompts are left as plain strings. A model routed to a
// non-listed provider (incl. an OpenRouter fallback) never gets the marker.
const CACHEABLE_MODEL_PREFIXES = ["anthropic/", "google/"];
function supportsExplicitPromptCache(model: unknown): boolean {
    return typeof model === "string" && CACHEABLE_MODEL_PREFIXES.some((p) => model.startsWith(p));
}

// The chat prompt's bulk — the meeting transcript + recap — rides in the system
// message. In the multi-turn Q&A chat it repeats verbatim on every turn, so
// marking it with a cache_control breakpoint lets Anthropic/Gemini serve that
// stable prefix from cache (~10% of input price) on later turns instead of
// re-billing it each question.
//
// Caching is OPT-IN via the client's `cache_prompt` flag, NOT applied to every
// `kind:chat` call. This is deliberate: the single-shot generation calls
// (summary, title, recap, entities — also `kind:chat`) each send a large, unique
// transcript prompt exactly once, so a cache_control marker there is a cache
// *write* (billed above base input) that's never read — a net surcharge. Only
// the true multi-turn chat sets the flag. The flag is internal, so it's stripped
// from the payload before forwarding upstream.
//
// (Sub-minimum prefixes — under 1k tokens on Sonnet, 4k on Haiku/Opus/Gemini Pro —
// are ignored upstream, so a marker on a small chat prompt is a harmless no-op.)
function applyPromptCaching(payload: Record<string, unknown>): Record<string, unknown> {
    const { cache_prompt, ...rest } = payload as Record<string, unknown> & { cache_prompt?: unknown };
    // Always drop the internal flag so it never reaches OpenRouter, regardless
    // of whether we end up marking the prompt.
    if (cache_prompt !== true || !supportsExplicitPromptCache(rest.model) || !Array.isArray(rest.messages)) {
        return rest;
    }
    let marked = false;
    const messages = (rest.messages as unknown[]).map((m) => {
        if (marked || !isObject(m) || m.role !== "system" || typeof m.content !== "string") return m;
        marked = true;
        return {
            ...m,
            content: [{ type: "text", text: m.content, cache_control: { type: "ephemeral" } }],
        };
    });
    return { ...rest, messages };
}

async function forwardChat(rawPayload: unknown, userId: string): Promise<Response> {
    const model = isObject(rawPayload) && typeof rawPayload.model === "string" ? rawPayload.model : "unknown";

    if (!isObject(rawPayload)) {
        return json({ error: "invalid chat payload" }, 400);
    }

    // Apply prompt caching when the client opted in (`cache_prompt`), and strip
    // that internal flag before forwarding. Non-opted calls pass through
    // unchanged. The client still sends plain string message content; the
    // cache_control content-block rewrite happens here.
    const payload = applyPromptCaching(rawPayload);

    // Streaming path (used by "Suggest reply"): pass the upstream SSE through
    // verbatim so the client renders tokens as they arrive. Usage is captured
    // off a teed copy of the stream — see forwardChatStream.
    if (payload.stream === true) {
        return forwardChatStream(payload, userId, model);
    }

    // One-shot path (typed chat question). We still consume OpenRouter as a
    // stream internally so the request is bounded by an idle watchdog, not the
    // old hard 30s total-duration cap — that cap 504'd chat whenever the
    // completion ran long (large-transcript meetings), even though tokens were
    // still flowing. The deltas are buffered back into the same one-shot JSON
    // the client already decodes, so the switch is invisible client-side.
    return forwardChatBuffered(payload, userId, model);
}

// Non-streaming chat served over an internal stream. Requests SSE from
// OpenRouter (so a long-but-progressing generation isn't killed by a fixed
// total timer), accumulates the deltas, and returns the assembled completion
// as the one-shot `{ choices: [{ message: { content } }] }` envelope the Swift
// client decodes. `usage: { include: true }` makes the terminal chunk carry
// `usage.cost` for accounting.
async function forwardChatBuffered(payload: Record<string, unknown>, userId: string, model: string): Promise<Response> {
    const enriched = {
        ...payload,
        stream: true,
        stream_options: { include_usage: true },
        usage: { include: true },
    };

    const started = Date.now();
    const controller = new AbortController();
    // Idle watchdog, matching forwardChatStream: abort only when the upstream
    // goes quiet for CHAT_TIMEOUT_MS (a hang before the first byte or a stall
    // mid-stream), never mid-answer while tokens are arriving.
    let lastActivity = Date.now();
    const watchdog = setInterval(() => {
        if (Date.now() - lastActivity > CHAT_TIMEOUT_MS) {
            console.warn(`chat-buffered user=${userId} idle >${CHAT_TIMEOUT_MS}ms — aborting`);
            controller.abort();
        }
    }, 5_000);

    try {
        let upstream: Response;
        try {
            upstream = await fetch(OPENROUTER_CHAT_URL, {
                method: "POST",
                headers: {
                    "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                    "Content-Type": "application/json",
                    "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                    "X-Title": "Nod",
                },
                body: JSON.stringify(enriched),
                signal: controller.signal,
            });
        } catch (error) {
            const aborted = error instanceof DOMException && error.name === "AbortError";
            console.error(`chat-buffered user=${userId} upstream ${aborted ? "timeout" : "error"}: ${error}`);
            return json({ error: aborted ? `Upstream timeout (idle ${CHAT_TIMEOUT_MS}ms)` : "Upstream request failed" }, aborted ? 504 : 502);
        }

        if (!upstream.ok || !upstream.body) {
            const text = await upstream.text().catch(() => "");
            console.error(`chat-buffered user=${userId} status=${upstream.status} (no stream body)`);
            return new Response(text || JSON.stringify({ error: "upstream error" }), {
                status: upstream.status || 502,
                headers: { "Content-Type": "application/json" },
            });
        }

        let assembled: BufferedChat;
        try {
            assembled = await readBufferedChat(upstream.body, () => { lastActivity = Date.now(); });
        } catch (error) {
            // The watchdog aborts the body read on an idle stall; a dropped
            // connection surfaces here too. Without this catch the rejection
            // escapes to Deno.serve as a generic 500 — defeating the 504 the
            // idle watchdog exists to return.
            const aborted = error instanceof DOMException && error.name === "AbortError";
            console.error(`chat-buffered user=${userId} stream ${aborted ? "timeout" : "error"}: ${error}`);
            return json({ error: aborted ? `Upstream timeout (idle ${CHAT_TIMEOUT_MS}ms)` : "Upstream stream failed" }, aborted ? 504 : 502);
        }
        const dt = Date.now() - started;
        console.log(`chat-buffered user=${userId} model=${model} status=${upstream.status} dt=${dt}ms chars=${assembled.content.length} tokens=${assembled.usage?.completion_tokens ?? "?"} prompt=${assembled.usage?.prompt_tokens ?? "?"} cached=${assembled.usage?.prompt_tokens_details?.cached_tokens ?? "?"}`);

        try {
            await recordUsage({
                user_id: userId,
                kind: "chat",
                model,
                status: upstream.status,
                prompt_tokens:     assembled.usage?.prompt_tokens     ?? null,
                completion_tokens: assembled.usage?.completion_tokens ?? null,
                generation_id:     assembled.id                       ?? null,
                cost_usd:          assembled.usage?.cost              ?? null,
            });
        } catch (err) {
            console.warn(`chat usage record skipped: ${err}`);
        }

        // An upstream error can arrive as a 200 body carrying an `error` chunk
        // with no content — surface it as 502 rather than an empty completion.
        if (!assembled.content && assembled.error) {
            console.error(`chat-buffered user=${userId} stream error: ${assembled.error}`);
            return json({ error: assembled.error }, 502);
        }

        const responseBody = {
            id: assembled.id,
            model,
            choices: [{
                index: 0,
                message: { role: "assistant", content: assembled.content },
                finish_reason: assembled.finishReason ?? "stop",
            }],
            usage: assembled.usage,
        };
        return new Response(JSON.stringify(responseBody), {
            status: upstream.status,
            headers: { "Content-Type": "application/json" },
        });
    } finally {
        clearInterval(watchdog);
    }
}

// Streaming chat: forward OpenRouter's SSE body straight to the client while
// teeing a copy to capture usage from the terminal chunk. `stream_options.
// include_usage` (OpenAI-compat) makes OpenRouter append a final `usage` chunk
// before `[DONE]`; we parse it off the teed branch so accounting survives the
// stream without buffering the bytes the user is waiting on.
async function forwardChatStream(payload: Record<string, unknown>, userId: string, model: string): Promise<Response> {
    const enriched = {
        ...payload,
        stream: true,
        stream_options: { include_usage: true },
        usage: { include: true },
    };

    const started = Date.now();
    const controller = new AbortController();
    // Idle watchdog, NOT a total-duration cap. A healthy stream can legitimately
    // run longer than CHAT_TIMEOUT_MS while delivering tokens — a fixed total
    // timer would abort mid-answer and truncate a long suggest-reply. Instead we
    // abort only when the upstream goes quiet for CHAT_TIMEOUT_MS, which covers
    // both a provider that hangs before the first byte and one that stalls
    // mid-stream. `lastActivity` is bumped per chunk from the meter callback.
    let lastActivity = Date.now();
    const watchdog = setInterval(() => {
        if (Date.now() - lastActivity > CHAT_TIMEOUT_MS) {
            console.warn(`chat-stream user=${userId} idle >${CHAT_TIMEOUT_MS}ms — aborting`);
            controller.abort();
        }
    }, 5_000);

    let upstream: Response;
    try {
        upstream = await fetch(OPENROUTER_CHAT_URL, {
            method: "POST",
            headers: {
                "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                "X-Title": "Nod",
            },
            body: JSON.stringify(enriched),
            signal: controller.signal,
        });
    } catch (error) {
        clearInterval(watchdog);
        const aborted = error instanceof DOMException && error.name === "AbortError";
        console.error(`chat-stream user=${userId} upstream ${aborted ? "timeout" : "error"}: ${error}`);
        return json({ error: "Upstream request failed" }, aborted ? 504 : 502);
    }

    if (!upstream.ok || !upstream.body) {
        clearInterval(watchdog);
        const text = await upstream.text().catch(() => "");
        console.error(`chat-stream user=${userId} status=${upstream.status} (no stream body)`);
        return new Response(text || JSON.stringify({ error: "upstream error" }), {
            status: upstream.status || 502,
            headers: { "Content-Type": "application/json" },
        });
    }

    // One branch to the client, one to the usage meter. The meter runs in the
    // background; a logging failure must never disturb the streamed bytes.
    const [toClient, toMeter] = upstream.body.tee();
    const meter = (async () => {
        try {
            const usage = await readStreamUsage(toMeter, () => { lastActivity = Date.now(); });
            const dt = Date.now() - started;
            console.log(`chat-stream user=${userId} model=${model} status=${upstream.status} dt=${dt}ms tokens=${usage?.completion_tokens ?? "?"} prompt=${usage?.prompt_tokens ?? "?"} cached=${usage?.prompt_tokens_details?.cached_tokens ?? "?"}`);
            await recordUsage({
                user_id: userId,
                kind: "chat",
                model,
                status: upstream.status,
                prompt_tokens:     usage?.prompt_tokens     ?? null,
                completion_tokens: usage?.completion_tokens ?? null,
                generation_id:     usage?.id                ?? null,
                cost_usd:          usage?.cost              ?? null,
            });
        } catch (err) {
            console.warn(`chat-stream usage record skipped: ${err}`);
        } finally {
            clearInterval(watchdog);
        }
    })();
    const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime?.waitUntil) runtime.waitUntil(meter);

    return new Response(toClient, {
        status: upstream.status,
        headers: {
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        },
    });
}

interface StreamUsage {
    prompt_tokens?: number | null;
    completion_tokens?: number | null;
    cost?: number | null;
    id?: string | null;
    // OpenRouter/Anthropic report cache activity here: `cached_tokens` is the
    // portion of the prompt served from cache (a hit), so a value > 0 on the
    // 2nd+ turn confirms prompt caching is working.
    prompt_tokens_details?: { cached_tokens?: number | null } | null;
}

// Drain a teed SSE stream and pull out the generation id + final usage chunk.
// Tolerant of partial lines across reads, keepalive comments, and malformed
// JSON — anything it can't parse is skipped rather than thrown.
async function readStreamUsage(
    stream: ReadableStream<Uint8Array>,
    onActivity?: () => void,
): Promise<StreamUsage | null> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let usage: StreamUsage | null = null;
    let id: string | null = null;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            onActivity?.();
            buf += decoder.decode(value, { stream: true });
            let nl: number;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (data === "[DONE]") continue;
                try {
                    const obj = JSON.parse(data);
                    if (typeof obj?.id === "string") id = obj.id;
                    if (obj?.usage) usage = obj.usage as StreamUsage;
                } catch { /* keepalive / split chunk — ignore */ }
            }
        }
    } finally {
        reader.releaseLock();
    }
    if (usage) return { ...usage, id };
    return id ? { id } : null;
}

interface BufferedChat {
    content: string;
    usage: StreamUsage | null;
    id: string | null;
    finishReason: string | null;
    error: string | null;
}

// Drain an SSE chat stream into a complete assembled reply: concatenated
// `delta.content`, plus the id, finish_reason, terminal usage, and any upstream
// error chunk. Same tolerant line parsing as readStreamUsage — unparsable lines
// (keepalives, split chunks) are skipped, never thrown.
async function readBufferedChat(
    stream: ReadableStream<Uint8Array>,
    onActivity?: () => void,
): Promise<BufferedChat> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let content = "";
    let usage: StreamUsage | null = null;
    let id: string | null = null;
    let finishReason: string | null = null;
    let error: string | null = null;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            onActivity?.();
            buf += decoder.decode(value, { stream: true });
            let nl: number;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (data === "[DONE]") continue;
                try {
                    const obj = JSON.parse(data);
                    if (typeof obj?.id === "string") id = obj.id;
                    if (obj?.usage) usage = obj.usage as StreamUsage;
                    if (obj?.error) {
                        error = typeof obj.error?.message === "string" ? obj.error.message : JSON.stringify(obj.error);
                    }
                    const choice = obj?.choices?.[0];
                    if (typeof choice?.delta?.content === "string") content += choice.delta.content;
                    if (typeof choice?.finish_reason === "string") finishReason = choice.finish_reason;
                } catch { /* keepalive / split chunk — ignore */ }
            }
        }
    } finally {
        reader.releaseLock();
    }
    return { content, usage: usage ? { ...usage, id } : null, id, finishReason, error };
}

// STT providers (Groq, OpenAI, OpenRouter) don't return a per-request cost the
// way OpenRouter's chat endpoint does, so we estimate it from the audio
// duration × a per-provider rate. The rate card lives in `app_config.stt_rates`
// (not a code constant) so a provider price change is a one-row UPDATE, not a
// redeploy — and the monthly reconciliation cron reads the same source. Shape:
//   { "<provider>": { "default": <$/h>, "min_billed_seconds": <int>,
//                     "models": { "<model id>": <$/h> } } }
// `min_billed_seconds` captures provider billing floors (Groq bills a 10s
// minimum per request; our VAD segments average ~5s, so raw duration would
// understate cost ~2x). `models` overrides the per-provider default for a
// specific model id; OpenAI always serves whisper-1 so its default ($0.36/h)
// covers every requested id.
interface SttProviderRates {
    default: number;
    min_billed_seconds?: number;
    models?: Record<string, number>;
}
type SttRates = Record<string, SttProviderRates>;

// Used only when app_config is unreadable — Groq large-v3 list price + 10s floor.
const STT_RATES_FALLBACK: SttRates = {
    groq: { default: 0.111, min_billed_seconds: 10, models: { "openai/whisper-large-v3-turbo": 0.04, "openai/whisper-large-v3": 0.111 } },
    openai: { default: 0.36, min_billed_seconds: 0 },
    openrouter: { default: 0.111, min_billed_seconds: 0, models: { "openai/whisper-large-v3-turbo": 0.04, "openai/whisper-large-v3": 0.111 } },
};

let cachedSttRates: { value: SttRates; at: number } | null = null;
const STT_RATES_TTL_MS = 60_000;

async function sttRates(admin: ReturnType<typeof adminClient>): Promise<SttRates> {
    const now = Date.now();
    if (cachedSttRates && now - cachedSttRates.at < STT_RATES_TTL_MS) return cachedSttRates.value;
    const { data, error } = await admin
        .from("app_config")
        .select("stt_rates")
        .eq("singleton", true)
        .single();
    const value = (!error && isObject(data) && isObject(data.stt_rates))
        ? data.stt_rates as SttRates
        : STT_RATES_FALLBACK;
    cachedSttRates = { value, at: now };
    return value;
}

// Estimated cost for one transcription. Returns null when we can't price the
// row (unknown provider) so it stays honestly empty rather than fabricated.
function transcribeCostUsd(rates: SttRates, provider: string, model: string, audioSeconds: number | null): number | null {
    if (audioSeconds == null || audioSeconds <= 0) return null;
    // Fall back to the built-in card if a hand-edited config omits a provider,
    // so a provider that actually served still records a cost.
    const p = rates[provider] ?? STT_RATES_FALLBACK[provider];
    if (!p) return null;
    const rate = p.models?.[model] ?? p.default;
    if (typeof rate !== "number") return null;
    const floor = typeof p.min_billed_seconds === "number" ? p.min_billed_seconds : 0;
    const billedSeconds = Math.max(audioSeconds, floor);
    // Match the column precision: numeric(12, 6).
    return Math.round((billedSeconds / 3600) * rate * 1e6) / 1e6;
}

async function forwardTranscribe(payload: unknown, userId: string, entitlement: Entitlement | null, admin: ReturnType<typeof adminClient>): Promise<Response> {
    const model = isObject(payload) && typeof payload.model === "string" ? payload.model : "unknown";
    const audioSeconds = audioSecondsFromPayload(payload);

    const { status, text, provider } = await callTranscribe(payload, userId);

    // One unmissable line per transcription so the serving provider is visible
    // in the function logs (the per-provider call logs are noisier).
    console.log(`transcribe served user=${userId} provider=${provider} status=${status} model=${model}`);

    try {
        // Providers return no usage for audio, so estimate from duration × the
        // per-provider rate card in app_config. Only price — and only fetch the
        // rate card — for successful calls; a failed upstream wasn't billable.
        const cost = status >= 200 && status < 300
            ? transcribeCostUsd(await sttRates(admin), provider, model, audioSeconds)
            : null;
        await recordUsage({
            user_id: userId,
            kind: "transcribe",
            // Tag the serving provider into the model field so cost reconciliation
            // + the eval harness can attribute WER/$ per provider, not just per
            // model id (Groq large-v3 and an OpenAI whisper-1 fallback are very
            // different rows). `unknown` model still records as e.g. `groq:unknown`.
            model: `${provider}:${model}`,
            status,
            audio_seconds: audioSeconds,
            cost_usd: cost,
        });
    } catch (err) {
        console.warn(`transcribe usage record skipped: ${err}`);
    }

    // Soft cap: the call is always served (no hard stop). The response carries
    // the user's hours-used/limit so the client can show how much of the plan's
    // monthly allowance is left.
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    // Surface the serving provider to the client so the app can log which STT
    // path ran (groq / openai / openrouter) without digging in dashboard logs.
    headers["x-nod-stt-provider"] = provider;
    if (entitlement && entitlement.hours_limit > 0) {
        headers["x-nod-hours-used"] = String(entitlement.hours_used);
        headers["x-nod-hours-limit"] = String(entitlement.hours_limit);
    }

    return new Response(text, { status, headers });
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
interface STTResult extends CallResult { provider: string }

// An OpenAI-compatible multipart STT endpoint. Groq and OpenAI both speak this
// shape; only the model-id mapping and host differ. OpenRouter is NOT one of
// these — it takes base64-JSON and is handled by the legacy `callOpenRouter`
// path as the terminal fallback.
interface STTProvider {
    name: string;
    url: string;
    apiKey: string;
    mapModel: (clientModel: string) => string;
}

// Multipart provider chain in priority order, filtered to those whose key is
// configured. Empty until GROQ_API_KEY / OPENAI_API_KEY land — that's the
// env-gated cutover: with neither set, `callTranscribe` uses OpenRouter alone,
// so this deploy changes nothing until the secret is added.
function sttMultipartChain(): STTProvider[] {
    const chain: STTProvider[] = [];
    if (GROQ_API_KEY) {
        chain.push({
            name: "groq",
            url: GROQ_TRANSCRIBE_URL,
            apiKey: GROQ_API_KEY,
            // The client sends OpenRouter-style vendor-prefixed ids
            // ("openai/whisper-large-v3-turbo"); Groq hosts the same weights
            // under the bare id.
            mapModel: (m) => m.replace(/^openai\//, ""),
        });
    }
    if (OPENAI_API_KEY) {
        chain.push({
            name: "openai",
            url: OPENAI_TRANSCRIBE_URL,
            apiKey: OPENAI_API_KEY,
            // OpenAI's transcription API only exposes whisper-1 (large-v2). Used
            // purely as a reliability fallback when Groq rate-limits/stalls — not
            // for output parity with Groq's large-v3.
            mapModel: () => "whisper-1",
        });
    }
    return chain;
}

// Statuses worth failing over to the next provider. Beyond 429/5xx we also fail
// over on 401/403 (a rotated/over-quota key on ONE provider must not take down
// transcription when another is configured) and 408 (request timeout). We do
// NOT fail over on a genuine bad request (400/404/422) — that fails the same way
// everywhere, so surfacing it is correct.
function shouldFailover(status: number): boolean {
    return status === 401 || status === 403 || status === 408 ||
        status === 409 || status === 429 || status >= 500;
}

// base64 → bytes. `atob` is a Deno global; `Uint8Array.from(str, map)` avoids an
// explicit per-char JS loop over the (up to ~2 MB) WAV on the CPU-budgeted edge
// worker. The client always posts a complete standard-base64 WAV.
function decodeBase64(b64: string): Uint8Array<ArrayBuffer> {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

// Transcribe via the provider chain: each multipart provider in turn (failing
// over on transient errors), then OpenRouter as the legacy/terminal fallback.
// Returns which provider actually served, for usage attribution.
async function callTranscribe(payload: unknown, userId: string): Promise<STTResult> {
    let last: STTResult | null = null;
    for (const p of sttMultipartChain()) {
        const r = await callMultipartSTT(p, payload, userId);
        if (!shouldFailover(r.status)) return { ...r, provider: p.name };
        console.warn(`transcribe provider=${p.name} status=${r.status} — failing over`);
        last = { ...r, provider: p.name };
    }
    if (OPENROUTER_API_KEY) {
        const r = await callOpenRouter(OPENROUTER_TRANSCRIBE_URL, payload, TRANSCRIBE_TIMEOUT_MS, userId, "transcribe");
        return { ...r, provider: "openrouter" };
    }
    return last ?? { status: 502, text: JSON.stringify({ error: "no STT provider configured" }), provider: "none" };
}

// POST the audio to an OpenAI-compatible multipart endpoint. The client→proxy
// contract stays base64-JSON (provider-agnostic); the translation to a file
// upload happens here so swapping providers never touches the client.
async function callMultipartSTT(p: STTProvider, payload: unknown, userId: string): Promise<CallResult> {
    if (!isObject(payload)) {
        return { status: 400, text: JSON.stringify({ error: "transcribe payload must be an object" }) };
    }
    const inputAudio = isObject(payload.input_audio) ? payload.input_audio : null;
    if (!inputAudio || typeof inputAudio.data !== "string") {
        return { status: 400, text: JSON.stringify({ error: "transcribe payload missing input_audio.data" }) };
    }

    let bytes: Uint8Array<ArrayBuffer>;
    try {
        bytes = decodeBase64(inputAudio.data);
    } catch {
        return { status: 400, text: JSON.stringify({ error: "input_audio.data is not valid base64" }) };
    }

    const format = typeof inputAudio.format === "string" ? inputAudio.format : "wav";
    const model = typeof payload.model === "string" ? p.mapModel(payload.model) : "whisper-large-v3";

    const form = new FormData();
    form.append("file", new Blob([bytes], { type: `audio/${format}` }), `audio.${format}`);
    form.append("model", model);
    if (typeof payload.language === "string" && payload.language.length > 0) form.append("language", payload.language);
    if (typeof payload.prompt === "string" && payload.prompt.length > 0) form.append("prompt", payload.prompt);
    if (typeof payload.temperature === "number") form.append("temperature", String(payload.temperature));
    if (typeof payload.response_format === "string") form.append("response_format", payload.response_format);
    if (Array.isArray(payload.timestamp_granularities)) {
        for (const g of payload.timestamp_granularities) {
            if (typeof g === "string") form.append("timestamp_granularities[]", g);
        }
    }

    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TRANSCRIBE_TIMEOUT_MS);
    try {
        // Note: no Content-Type header — fetch derives the multipart boundary
        // from the FormData body. Setting it manually breaks the upload.
        const upstream = await fetch(p.url, {
            method: "POST",
            headers: { "Authorization": `Bearer ${p.apiKey}` },
            body: form,
            signal: controller.signal,
        });
        const text = await upstream.text();
        const dt = Date.now() - started;
        console.log(`transcribe user=${userId} provider=${p.name} model=${model} status=${upstream.status} dt=${dt}ms bytes=${text.length}`);
        return { status: upstream.status, text };
    } catch (error) {
        const dt = Date.now() - started;
        if (error instanceof DOMException && error.name === "AbortError") {
            console.error(`transcribe provider=${p.name} user=${userId} timeout after ${dt}ms`);
            return { status: 504, text: JSON.stringify({ error: `Upstream timeout (${TRANSCRIBE_TIMEOUT_MS}ms)` }) };
        }
        console.error(`transcribe provider=${p.name} user=${userId} upstream error: ${error}`);
        return { status: 502, text: JSON.stringify({ error: "Upstream request failed" }) };
    } finally {
        clearTimeout(timer);
    }
}

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
    const admin = adminClient();
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

// Which plan feature a search requires, by scope: a single-meeting question is
// Starter-tier (`ask_single_meeting`); a label-scoped question and a
// cross-session question are Pro (`label_scoping` / `ask_across_meetings`).
function requiredSearchFeature(payload: unknown): string {
    if (isObject(payload)) {
        if (Array.isArray(payload.meeting_ids) && payload.meeting_ids.length > 0) return "label_scoping";
        if (typeof payload.meeting_id === "string" && payload.meeting_id.length > 0) return "ask_single_meeting";
    }
    return "ask_across_meetings";
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

// The client percent-encodes the machine name (non-ASCII names are invalid in
// HTTP headers). Decode best-effort; a malformed value falls back to the raw
// header rather than dropping the name entirely.
function decodeDeviceName(raw: string | null): string | null {
    if (!raw) return null;
    try {
        return decodeURIComponent(raw);
    } catch {
        return raw;
    }
}
