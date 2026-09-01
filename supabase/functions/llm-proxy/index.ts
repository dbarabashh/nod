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
import { isObject, json } from "../_shared/http.ts";
import { ROUTING_VERSION } from "../_shared/model-policy.ts";
import { callTranscribe } from "../_shared/stt-providers.ts";
import { forwardChat } from "../_shared/chat.ts";
import { recordUsage } from "../_shared/usage.ts";
import { audioSecondsFromPayload, reportedCostUsd, sttRates, transcribeCostUsd } from "../_shared/stt-cost.ts";
import { handleIndex, handleSearch, requiredSearchFeature } from "../_shared/search.ts";
import { handleDistill } from "../_shared/knowledge.ts";
import { leaseConflictStatus, meetingIdFromPayload, transcribeLeasePayload } from "../_shared/meeting-lease.ts";

const OPENROUTER_API_KEY        = Deno.env.get("OPENROUTER_API_KEY");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");


// A device holds its account slot for this long without making a call. During
// a meeting the steady transcribe traffic keeps it fresh; once the app quits
// or sits idle past this window the slot frees so another device can claim it
// (the "timeout" half of the single-device lock — see claim_device migration).
const DEVICE_ACTIVE_TTL_SECONDS = 900;


type Kind =
    | "chat"
    | "transcribe"
    | "index"
    | "search"
    | "distill"
    | "device_claim"
    | "device_release"
    | "meeting_start"
    | "meeting_end";

interface ProxyRequest {
    kind: Kind;
    payload: unknown;
}

// The set `app_config.platform` is constrained to (migration
// `mobile_platform_support`). Every client shipped before `x-app-platform`
// existed is a Mac, so that is the fallback — and an unrecognised value has to
// fall back too, because `.single()` on a platform with no `app_config` row
// errors, which fails every gate open.
type Platform = "macos" | "ios";
const SUPPORTED_PLATFORMS: readonly Platform[] = ["macos", "ios"];

function clientPlatform(req: Request): Platform {
    const raw = req.headers.get("x-app-platform")?.trim().toLowerCase();
    return SUPPORTED_PLATFORMS.find((p) => p === raw) ?? "macos";
}

// `app_config` build thresholds, cached per warm instance so neither gate adds a
// DB round-trip to every proxy call — a meeting hour is hundreds of calls.
// 0 (fail-open) for the version gate when the row can't be read; the lease
// threshold stays unreachable in that case, so a config blip can only ever be
// more permissive, never cut a live recording.
interface BuildGates {
    minimumBuild: number;
    meetingLeaseRequiredBuild: number;
}

const BUILD_GATES_TTL_MS = 60_000;
const UNREACHABLE_BUILD = 2_147_483_647;
const cachedBuildGates = new Map<Platform, { value: BuildGates; at: number }>();

async function buildGates(admin: ReturnType<typeof adminClient>, platform: Platform): Promise<BuildGates> {
    const now = Date.now();
    const cached = cachedBuildGates.get(platform);
    if (cached && now - cached.at < BUILD_GATES_TTL_MS) return cached.value;
    const { data, error } = await admin
        .from("app_config")
        .select("minimum_build, meeting_lease_required_build")
        .eq("platform", platform)
        .single();
    // Silence is how the `singleton` column drop (2026-08-06) kept the version
    // gate switched off for days while the config said it was enforcing, so a
    // read failure is loud.
    if (error) {
        console.error(`app_config build gates unreadable for ${platform}, failing open: ${error.message}`);
    }
    const value: BuildGates = {
        minimumBuild: (!error && data && typeof data.minimum_build === "number") ? data.minimum_build : 0,
        meetingLeaseRequiredBuild: (!error && data && typeof data.meeting_lease_required_build === "number")
            ? data.meeting_lease_required_build
            : UNREACHABLE_BUILD,
    };
    cachedBuildGates.set(platform, { value, at: now });
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
// `meeting_start` carries the allowance check itself (atomically, in the RPC),
// and `meeting_end` is cleanup that must work even on a lapsed plan.
const UNGATED_KINDS = new Set(["device_claim", "device_release", "meeting_start", "meeting_end"]);

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
    const platform = clientPlatform(req);
    const appBuild = parseInt(req.headers.get("x-app-build") ?? "", 10) || 0;
    const gates = await buildGates(admin, platform);
    if (appBuild < gates.minimumBuild) {
        return json({ error: "update_required", minimum_build: gates.minimumBuild }, 426);
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
                p_platform: platform,
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
    // A NEW meeting is blocked by `meeting_start` instead: the lease decides
    // once, up front, so this path never has to tell a new recording from a
    // continued one.
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

    // The recording's start lease. A chunk presents the meeting id it belongs
    // to; the id is stripped before the payload reaches a provider. Validation
    // runs whenever an id is present — that call is also the lease's heartbeat,
    // so an active recording keeps its slot even before enforcement is on — but
    // it can only BLOCK once a build that speaks the protocol is the minimum.
    let transcribePayload = body.payload;
    if (body.kind === "transcribe") {
        const parsed = transcribeLeasePayload(body.payload);
        const leaseRequired = appBuild >= gates.meetingLeaseRequiredBuild;
        if (!parsed) {
            if (leaseRequired) return json({ error: "meeting_lease_required" }, 403);
        } else {
            transcribePayload = parsed.upstreamPayload;
            const { data: valid, error } = await admin.rpc("validate_meeting_lease", {
                p_user_id: user.id,
                p_meeting_id: parsed.meetingId,
            });
            if (error) {
                // Never cut a live meeting over a DB hiccup.
                console.error(`meeting lease validation failed user=${user.id}: ${error.message}`);
                if (leaseRequired) return json({ error: "meeting_lease_unavailable" }, 503);
            } else if (valid !== true && leaseRequired) {
                return json({ error: "meeting_lease_required" }, 403);
            }
        }
    }

    switch (body.kind) {
        case "device_claim":
            // Reaching here means the device passed the lock above.
            return json({ ok: true }, 200);
        case "chat":
            return forwardChat(body.payload, user.id);
        case "meeting_start":
            return startMeeting(admin, user.id, body.payload);
        case "meeting_end":
            return endMeeting(admin, user.id, body.payload);
        case "transcribe":
            return forwardTranscribe(transcribePayload, user.id, entitlement, admin);
        case "index":
            return handleIndex(body.payload, user.id);
        case "search":
            return handleSearch(body.payload, user.id);
        case "distill":
            return handleDistill(body.payload, user.id);
        default:
            return json({ error: `Unknown kind: ${body.kind}` }, 400);
    }
});

// Allowance is enforced here, once, before any audio exists — not per chunk.
// `start_meeting_lease` decides atomically, so two simultaneous starts cannot
// both pass a cap with one hour left.
async function startMeeting(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    payload: unknown,
): Promise<Response> {
    const meetingId = meetingIdFromPayload(payload);
    if (!meetingId) return json({ error: "invalid_meeting_id" }, 400);

    const { data, error } = await admin.rpc("start_meeting_lease", {
        p_user_id: userId,
        p_meeting_id: meetingId,
    });
    if (error || !isObject(data)) {
        console.error(`meeting start failed user=${userId}: ${error?.message ?? "unexpected response"}`);
        return json({ error: "meeting_lease_unavailable" }, 503);
    }
    if (data.granted === true) return json(data, 200);
    const code = typeof data.error === "string" ? data.error : "meeting_limit_reached";
    return json(data, leaseConflictStatus(code));
}

// Best-effort by design: the client fires this at End and does not wait. A lost
// call only means the lease expires on its own a few minutes later.
async function endMeeting(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    payload: unknown,
): Promise<Response> {
    const meetingId = meetingIdFromPayload(payload);
    if (!meetingId) return json({ error: "invalid_meeting_id" }, 400);

    const { data, error } = await admin.rpc("end_meeting_lease", {
        p_user_id: userId,
        p_meeting_id: meetingId,
    });
    if (error) {
        console.error(`meeting end failed user=${userId}: ${error.message}`);
        return json({ error: "meeting_lease_unavailable" }, 503);
    }
    return json({ ended: data === true, meeting_id: meetingId }, 200);
}

async function forwardTranscribe(payload: unknown, userId: string, entitlement: Entitlement | null, admin: ReturnType<typeof adminClient>): Promise<Response> {
    const model = isObject(payload) && typeof payload.model === "string" ? payload.model : "unknown";
    const audioSeconds = audioSecondsFromPayload(payload);

    const { status, text, provider, failover } = await callTranscribe(payload, userId);

    // One unmissable line per transcription so the serving provider is visible
    // in the function logs (the per-provider call logs are noisier).
    const trail = failover.map((a) => `${a.provider}:${a.status}/${a.reason}`).join(">");
    console.log(`transcribe served user=${userId} provider=${provider} status=${status} model=${model} failover=${trail || "-"}`);

    try {
        // Price only successful calls — a failed upstream wasn't billable. Take
        // the provider's own figure when it reports one and fall back to
        // duration × the app_config rate card otherwise, so the estimate covers
        // exactly the providers that stay silent (Groq, OpenAI).
        const served = status >= 200 && status < 300;
        const reported = served ? reportedCostUsd(text) : null;
        const cost = served
            ? reported ?? transcribeCostUsd(await sttRates(admin), provider, model, audioSeconds)
            : null;
        if (served && reported === null && provider === "openrouter") {
            console.warn(`transcribe cost fell back to the rate card — openrouter reported no usage.cost`);
        }
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
            failover: failover.length > 0 ? failover : null,
            task: "stt",
            routing_version: ROUTING_VERSION,
            requested_model: model,
            resolved_model: `${provider}:${model}`,
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
