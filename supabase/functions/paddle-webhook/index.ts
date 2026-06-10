// paddle-webhook — the ONLY thing that writes a user's plan in production.
//
// Paddle calls this (no Supabase JWT — deploy with verify_jwt = false) whenever
// a subscription or transaction changes. We verify the `Paddle-Signature`
// HMAC before trusting a single byte, then map the event onto the entitlement
// schema via service-role RPCs (`apply_paddle_subscription` /
// `apply_paddle_overage`). The client never sees any of this; it just re-reads
// `get_entitlement()` and finds itself upgraded.
//
// Event handling (per Paddle's guidance — subscription.updated already covers
// renewals, upgrades, downgrades, pauses, and past_due):
//   subscription.created / .updated / .activated / .canceled / .past_due /
//   .paused / .resumed  → upsert the subscription (plan + status + period)
//   transaction.completed → record any overage hour-pack line items
//
// Secret (set via `supabase secrets set`, or a local --env-file):
//   PADDLE_WEBHOOK_SECRET — the destination's signing secret (`pdl_ntfset_…`)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const PADDLE_WEBHOOK_SECRET     = Deno.env.get("PADDLE_WEBHOOK_SECRET");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

function adminClient() {
    return createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!, {
        auth: { persistSession: false, autoRefreshToken: false },
    });
}

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
        } else if (type === "transaction.completed") {
            await handleTransaction(admin, data);
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
    const customerId     = str(data.customer_id);
    const status         = str(data.status);
    const priceId        = firstPriceId(data.items);
    const period         = isObject(data.current_billing_period) ? data.current_billing_period : {};
    const periodStart    = str(period.starts_at);
    const periodEnd      = str(period.ends_at);

    const userId = await resolveUserId(admin, data, subscriptionId, customerId);
    if (!userId) {
        console.warn(`subscription event without resolvable user — sub=${subscriptionId} customer=${customerId}`);
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

async function handleTransaction(admin: ReturnType<typeof adminClient>, data: Record<string, unknown>): Promise<void> {
    const transactionId = str(data.id);
    const userId = await resolveUserId(admin, data, str(data.subscription_id), str(data.customer_id));
    if (!userId || !transactionId) return;

    // Call apply_paddle_overage for every line item; it no-ops on prices that
    // aren't overage packs, so subscription line items are harmlessly skipped.
    const items = Array.isArray(data.items) ? data.items : [];
    for (const item of items) {
        const priceId = isObject(item) && isObject(item.price) ? str(item.price.id) : str(isObject(item) ? item.price_id : undefined);
        if (!priceId) continue;
        const { error } = await admin.rpc("apply_paddle_overage", {
            p_user_id:        userId,
            p_transaction_id: transactionId,
            p_price_id:       priceId,
        });
        if (error) throw new Error(`apply_paddle_overage: ${error.message}`);
    }
}

// Prefer the custom_data breadcrumb our own checkout stamps; fall back to
// matching the subscription/customer id against an existing row for events that
// originated outside our flow.
async function resolveUserId(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    subscriptionId: string,
    customerId: string,
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
// `<ts>:<rawBody>`, HMAC-SHA256'd with the destination's secret. Constant-time
// compared against h1.
async function verifySignature(header: string, body: string, secret: string): Promise<boolean> {
    const parts = Object.fromEntries(
        header.split(";").map((p) => {
            const idx = p.indexOf("=");
            return [p.slice(0, idx).trim(), p.slice(idx + 1).trim()];
        }),
    );
    const ts = parts["ts"];
    const h1 = parts["h1"];
    if (!ts || !h1) return false;

    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const sigBytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}:${body}`));
    const computed = [...new Uint8Array(sigBytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return timingSafeEqual(computed, h1);
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

function firstPriceId(items: unknown): string {
    if (!Array.isArray(items)) return "";
    const first = items[0];
    if (!isObject(first)) return "";
    if (isObject(first.price)) return str(first.price.id);
    return str(first.price_id);
}

function str(value: unknown): string {
    return typeof value === "string" ? value : "";
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
