// paddle-webhook — the ONLY thing that writes a user's plan in production.
//
// Paddle calls this (no Supabase JWT — deploy with verify_jwt = false) whenever
// a subscription changes. We verify the `Paddle-Signature` HMAC before trusting
// a single byte, then map the event onto the entitlement schema via the
// service-role RPC `apply_paddle_subscription`. The client never sees any of
// this; it just re-reads `get_entitlement()` and finds itself upgraded.
//
// Event handling (per Paddle's guidance — subscription.updated already covers
// renewals, upgrades, downgrades, pauses, and past_due):
//   subscription.created / .updated / .activated / .canceled / .past_due /
//   .paused / .resumed  → upsert the subscription (plan + status + period)
//
// Secret (set via `supabase secrets set`, or a local --env-file):
//   PADDLE_WEBHOOK_SECRET — the destination's signing secret (`pdl_ntfset_…`)
//
// Deployed per-branch via git: the `develop` branch (sandbox secret) and
// `main` (live secret) each get their own copy from their git branch.

import { adminClient } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";

// Reject a validly-signed delivery whose `ts` is older than this — a captured
// event (e.g. an old `subscription.activated`) can't be replayed later to
// re-grant access. Generous enough to tolerate clock skew + Paddle's own
// retries, which each carry a fresh signature.
const SIGNATURE_MAX_AGE_SECONDS = 300;

const PADDLE_WEBHOOK_SECRET     = Deno.env.get("PADDLE_WEBHOOK_SECRET");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    if (!PADDLE_WEBHOOK_SECRET || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: PADDLE_WEBHOOK_SECRET / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    // Read the body as raw text — the signature is computed over the exact
    // bytes Paddle sent, so re-serialising parsed JSON would break it.
    const rawBody = await req.text();
    const signature = req.headers.get("Paddle-Signature");
    if (!signature || !(await verifySignature(signature, rawBody, PADDLE_WEBHOOK_SECRET))) {
        console.warn("paddle webhook signature verification failed");
        return json({ error: "Invalid signature" }, 401);
    }

    let event: PaddleEvent;
    try {
        event = JSON.parse(rawBody);
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }

    const type = event.event_type ?? "";
    const data = isObject(event.data) ? event.data : {};
    const admin = adminClient();

    try {
        if (type.startsWith("subscription.")) {
            await handleSubscription(admin, data);
        } else {
            console.log(`paddle webhook ignored event_type=${type}`);
        }
    } catch (err) {
        // 500 so Paddle retries — but only for genuinely transient failures.
        // A bad-shape event is logged and acked (200) so it isn't retried
        // forever.
        console.error(`paddle webhook handler error type=${type}: ${err}`);
        return json({ error: "Handler error" }, 500);
    }

    return json({ ok: true }, 200);
});

async function handleSubscription(admin: ReturnType<typeof adminClient>, data: Record<string, unknown>): Promise<void> {
    const subscriptionId = str(data.id);
    const customerId     = nullableStr(data.customer_id);
    const status         = str(data.status);
    const priceId        = firstPriceId(data.items);
    const period         = isObject(data.current_billing_period) ? data.current_billing_period : {};
    // Pass null (not "") when a period is absent — the RPC params are timestamptz,
    // and PostgREST rejects "" with 'invalid input syntax', 500ing the webhook into
    // an infinite retry. null lets the RPC's coalesce keep the stored period.
    const periodStart    = nullableStr(period.starts_at);
    const periodEnd      = nullableStr(period.ends_at);

    const userId = await resolveUserId(admin, data, subscriptionId, customerId);
    if (!userId) {
        console.warn(`subscription event without resolvable user — sub=${subscriptionId} customer=${customerId}`);
        return;
    }
    if (!subscriptionId) {
        console.warn("subscription event missing data.id — skipping");
        return;
    }

    const { error } = await admin.rpc("apply_paddle_subscription", {
        p_user_id:         userId,
        p_customer_id:     customerId,
        p_subscription_id: subscriptionId,
        p_price_id:        priceId,
        p_paddle_status:   status,
        p_period_start:    periodStart,
        p_period_end:      periodEnd,
    });
    if (error) throw new Error(`apply_paddle_subscription: ${error.message}`);
    console.log(`subscription applied user=${userId} status=${status} price=${priceId}`);
}

// Prefer the custom_data breadcrumb our own checkout stamps; fall back to
// matching the subscription/customer id against an existing row for events that
// originated outside our flow.
async function resolveUserId(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    subscriptionId: string,
    customerId: string | null,
): Promise<string | null> {
    const custom = isObject(data.custom_data) ? data.custom_data : {};
    const fromCustom = str(custom.user_id);
    if (fromCustom) return fromCustom;

    let query = admin.from("subscriptions").select("user_id").limit(1);
    if (subscriptionId) query = query.eq("paddle_subscription_id", subscriptionId);
    else if (customerId) query = query.eq("paddle_customer_id", customerId);
    else return null;

    const { data: row } = await query.maybeSingle();
    return row?.user_id ?? null;
}

// Paddle-Signature: `ts=<unix>;h1=<hex hmac>`. The signed payload is
// `<ts>:<rawBody>`, HMAC-SHA256'd with the destination's secret, constant-time
// compared against h1. During a secret rotation Paddle sends MULTIPLE h1
// values in one header (`ts=…;h1=<old>;h1=<new>`), so collect them all and
// accept if any matches — a single `Object.fromEntries` would keep only the
// last and reject otherwise-valid deliveries mid-rotation.
async function verifySignature(header: string, body: string, secret: string): Promise<boolean> {
    let ts = "";
    const h1s: string[] = [];
    for (const part of header.split(";")) {
        const idx = part.indexOf("=");
        if (idx < 0) continue;
        const k = part.slice(0, idx).trim();
        const v = part.slice(idx + 1).trim();
        if (k === "ts") ts = v;
        else if (k === "h1") h1s.push(v);
    }
    if (!ts || h1s.length === 0) return false;

    // Replay guard: the signed `ts` (unix seconds) must be recent. Out-of-window
    // deliveries are rejected even with a valid HMAC.
    const tsSeconds = parseInt(ts, 10);
    if (!Number.isFinite(tsSeconds) || Math.abs(Date.now() / 1000 - tsSeconds) > SIGNATURE_MAX_AGE_SECONDS) {
        console.warn("paddle webhook signature timestamp outside replay window");
        return false;
    }

    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const sigBytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}:${body}`));
    const computed = [...new Uint8Array(sigBytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return h1s.some((h1) => timingSafeEqual(computed, h1));
}

function timingSafeEqual(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

interface PaddleEvent {
    event_type?: string;
    data?: unknown;
}

function firstPriceId(items: unknown): string | null {
    if (!Array.isArray(items)) return null;
    const first = items[0];
    if (!isObject(first)) return null;
    if (isObject(first.price)) return nullableStr(first.price.id);
    return nullableStr(first.price_id);
}

function str(value: unknown): string {
    return typeof value === "string" ? value : "";
}

function nullableStr(value: unknown): string | null {
    return typeof value === "string" && value.length > 0 ? value : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
