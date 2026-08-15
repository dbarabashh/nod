// paddle-webhook — the ONLY thing that writes a user's plan in production.
//
// Paddle calls this (no Supabase JWT — deploy with verify_jwt = false) whenever
// a subscription or transaction changes. We verify the `Paddle-Signature` HMAC before trusting
// a single byte, then map the event onto the entitlement schema via the
// service-role RPC `apply_paddle_subscription`. The client never sees any of
// this; it just re-reads `get_entitlement()` and finds itself upgraded.
//
// Event handling (per Paddle's guidance — subscription.updated already covers
// renewals, upgrades, downgrades, pauses, and past_due):
//   subscription.created / .updated / .activated / .canceled / .past_due /
//   .paused / .resumed  → upsert the subscription (plan + status + period),
//   ordered by the event's own id and timestamp so a redelivery can't regress it
//   transaction.completed → ads conversion, Starter top-up fulfilment, referral
//   activation/earning, and any due reward payout
//   adjustment.created / .updated → refunds and chargebacks
//
// Referral and reward decisions read only provider facts: the transaction id
// bound at checkout, whether this customer ever paid before, the configured
// first-period discount, and the billing period. Nothing depends on a code the
// client sent. Reward payout itself lives in `_shared/reward-payout.ts`.
//
// Secrets (set via `supabase secrets set`, or a local --env-file):
//   PADDLE_WEBHOOK_SECRET       — destination signing secret (`pdl_ntfset_…`)
//   PADDLE_API_KEY              — server-side API key (reward payout writes)
//   PADDLE_REFERRAL_DISCOUNT_ID — the first-period referral discount to verify
//
// Deployed per-branch via git: the `develop` branch (sandbox secret) and
// `main` (live secret) each get their own copy from their git branch.

import { adminClient } from "../_shared/supabase.ts";
import { isObject, json } from "../_shared/http.ts";
import { currencyAmount, paidSubscriptionTransaction } from "../_shared/paddle-transaction.ts";
import { payoutDueRewards } from "../_shared/reward-payout.ts";

// Reject a validly-signed delivery whose `ts` is older than this — a captured
// event (e.g. an old `subscription.activated`) can't be replayed later to
// re-grant access. Generous enough to tolerate clock skew + Paddle's own
// retries, which each carry a fresh signature.
const SIGNATURE_MAX_AGE_SECONDS = 300;

const PADDLE_WEBHOOK_SECRET     = Deno.env.get("PADDLE_WEBHOOK_SECRET");
const PADDLE_REFERRAL_DISCOUNT_ID = Deno.env.get("PADDLE_REFERRAL_DISCOUNT_ID");
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
        if (type === "transaction.completed") {
            await handleCompletedTransaction(admin, data, nullableStr(event.occurred_at));
        } else if (type.startsWith("subscription.")) {
            await handleSubscription(admin, data, nullableStr(event.event_id), nullableStr(event.occurred_at));
        } else if (type === "adjustment.created" || type === "adjustment.updated") {
            await handleAdjustment(admin, data, nullableStr(event.occurred_at));
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

// A completed transaction is the only fact that moves money, so it drives three
// things: the ads conversion, top-up fulfilment, and the referral lifecycle.
async function handleCompletedTransaction(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    eventOccurredAt: string | null,
): Promise<void> {
    const transactionId = str(data.id);
    if (!transactionId) {
        console.warn("completed transaction missing id");
        return;
    }
    const subscriptionId = nullableStr(data.subscription_id);
    const customerId = nullableStr(data.customer_id);
    const userId = await resolveUserId(admin, data, subscriptionId ?? "", customerId);
    const customData = isObject(data.custom_data) ? data.custom_data : {};
    const offerClaimId = nullableStr(customData.offer_claim_id);

    const paidTransaction = paidSubscriptionTransaction(data);
    if (paidTransaction && eventOccurredAt) {
        if (userId) {
            const { data: accepted, error } = await admin.rpc("enqueue_paid_transaction_conversion", {
                p_user_id: userId,
                p_occurred_at: eventOccurredAt,
                p_value: paidTransaction.value,
                p_currency: paidTransaction.currency,
            });
            if (error) throw new Error(`enqueue_paid_transaction_conversion: ${error.message}`);
            console.log(`paid conversion transaction=${transactionId} accepted=${accepted === true}`);
        } else {
            console.warn(`completed transaction without resolvable user — txn=${transactionId}`);
        }
    }

    // Paddle's own billing time, not our receive time: a delivery retried hours
    // later must not look like a later payment.
    const occurredAt = nullableStr(data.billed_at)
        ?? nullableStr(data.created_at)
        ?? eventOccurredAt
        ?? new Date().toISOString();
    const origin = str(data.origin);
    const billingPeriod = isObject(data.billing_period) ? data.billing_period : {};
    const billingPeriodStart = nullableStr(billingPeriod.starts_at);
    const discount = isObject(data.discount) ? data.discount : {};
    const discountId = nullableStr(data.discount_id) ?? nullableStr(discount.id);
    const referralDiscountApplied = !!PADDLE_REFERRAL_DISCOUNT_ID && discountId === PADDLE_REFERRAL_DISCOUNT_ID;

    for (const priceId of priceIds(data.items)) {
        const { data: price } = await admin
            .from("plan_prices")
            .select("kind")
            .eq("paddle_price_id", priceId)
            .maybeSingle();

        if (price?.kind === "topup") {
            await fulfilTopup(admin, transactionId, priceId, origin, occurredAt, data);
        } else if (price?.kind === "subscription") {
            if (!userId || !subscriptionId) {
                console.warn(`subscription transaction missing identity txn=${transactionId}`);
                continue;
            }
            // "First-ever payer" is a provider fact, so it is recorded before
            // the referral decision that depends on it.
            let isFirstPayerTransaction = false;
            if (customerId) {
                const { data: firstPayer, error: payerError } = await admin.rpc("record_billing_payer", {
                    p_paddle_customer_id: customerId,
                    p_user_id: userId,
                    p_transaction_id: transactionId,
                    p_paid_at: occurredAt,
                });
                if (payerError) throw new Error(`record_billing_payer: ${payerError.message}`);
                isFirstPayerTransaction = firstPayer === true;
            }

            const { data: result, error } = await admin.rpc("record_referral_transaction", {
                p_referee_user_id: userId,
                p_transaction_id: transactionId,
                p_price_id: priceId,
                p_occurred_at: occurredAt,
                p_origin: origin,
                p_subscription_id: subscriptionId,
                p_billing_period_start: billingPeriodStart,
                p_referral_discount_applied: referralDiscountApplied,
                p_is_first_payer_transaction: isFirstPayerTransaction,
            });
            if (error) throw new Error(`record_referral_transaction: ${error.message}`);
            console.log(`referral transaction user=${userId} txn=${transactionId} result=${JSON.stringify(result)}`);
        }
    }

    if (userId) await payoutDueRewards(admin, userId);
    if (userId && offerClaimId) {
        const { data: redeemed, error } = await admin.rpc("redeem_email_offer_transaction", {
            p_claim_id: offerClaimId,
            p_user_id: userId,
            p_transaction_id: transactionId,
        });
        if (error) throw new Error(`redeem_email_offer_transaction: ${error.message}`);
        console.log(`winback offer transaction=${transactionId} redeemed=${redeemed === true}`);
    }
}

// A top-up is fulfilled only against the intent that created its checkout. The
// intent id in custom_data is a bootstrap for the case where our own attach call
// never completed; it is verified against the stored row before it is trusted.
async function fulfilTopup(
    admin: ReturnType<typeof adminClient>,
    transactionId: string,
    priceId: string,
    origin: string,
    occurredAt: string,
    data: Record<string, unknown>,
): Promise<void> {
    if (origin !== "api") {
        console.warn(`top-up ignored for unexpected origin=${origin} txn=${transactionId}`);
        return;
    }

    let { data: intent, error: intentError } = await admin
        .from("topup_checkout_intents")
        .select("id, user_id, paddle_price_id")
        .eq("paddle_transaction_id", transactionId)
        .maybeSingle();

    if (!intent && !intentError) {
        const customData = isObject(data.custom_data) ? data.custom_data : {};
        const intentId = nullableStr(customData.topup_intent_id);
        if (intentId) {
            const { data: candidate, error: candidateError } = await admin
                .from("topup_checkout_intents")
                .select("id, user_id, paddle_price_id")
                .eq("id", intentId)
                .maybeSingle();
            if (!candidateError && candidate?.paddle_price_id === priceId) {
                const { data: attached, error: attachError } = await admin.rpc("attach_topup_checkout_transaction", {
                    p_intent_id: intentId,
                    p_transaction_id: transactionId,
                });
                if (!attachError && attached === true) intent = candidate;
                else intentError = attachError;
            } else {
                intentError = candidateError;
            }
        }
    }

    if (intentError || !intent || intent.paddle_price_id !== priceId) {
        console.error(`top-up transaction has no matching intent txn=${transactionId}`);
        return;
    }

    const { data: result, error } = await admin.rpc("apply_topup_purchase", {
        p_user_id: intent.user_id,
        p_transaction_id: transactionId,
        p_price_id: priceId,
        p_intent_id: intent.id,
    });
    if (error) throw new Error(`apply_topup_purchase: ${error.message}`);
    console.log(`top-up user=${intent.user_id} txn=${transactionId} result=${JSON.stringify(result)}`);

    // Only a genuinely applied purchase is a conversion; one parked for
    // reconciliation is not something to optimise ads against.
    if (isObject(result) && result.applied === true) {
        const { error: telemetryError } = await admin.rpc("record_server_product_event", {
            p_user_id: intent.user_id,
            p_event: "topup_purchased",
            p_properties: { plan: "starter", billing: "one_time", outcome: "success" },
        });
        if (telemetryError) console.warn(`top-up telemetry failed: ${telemetryError.message}`);

        const totals = isObject(data.details) && isObject(data.details.totals) ? data.details.totals : {};
        const value = currencyAmount(str(totals.earnings), str(data.currency_code).toUpperCase());
        if (value !== null) {
            const { error: conversionError } = await admin.rpc("enqueue_topup_conversion", {
                p_user_id: intent.user_id,
                p_occurred_at: occurredAt,
                p_value: value,
                p_currency: str(data.currency_code).toUpperCase(),
            });
            if (conversionError) console.warn(`top-up conversion failed: ${conversionError.message}`);
        }
    }
}

// Refunds and chargebacks. Recorded first (so a later reversal is visible), then
// applied: unapplied referral credit is cancelled, and a fully refunded top-up
// gives back only the hours nobody used.
async function handleAdjustment(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    eventOccurredAt: string | null,
): Promise<void> {
    const transactionId = str(data.transaction_id);
    if (!transactionId) return;

    const action = str(data.action);
    const status = str(data.status);
    const isApprovedRefund = action === "refund" && status === "approved";
    const isLiveChargeback = action === "chargeback" && status !== "rejected" && status !== "reversed";
    const isFull = action === "chargeback" || str(data.type) === "full";
    const reason = `${action}:${str(data.reason) || status}`;

    const { error: adjustmentError } = await admin.rpc("record_billing_adjustment", {
        p_transaction_id: transactionId,
        p_action: action,
        p_status: status,
        p_is_full: isFull,
        p_reason: reason,
        p_occurred_at: eventOccurredAt,
    });
    if (adjustmentError) throw new Error(`record_billing_adjustment: ${adjustmentError.message}`);
    if (!isApprovedRefund && !isLiveChargeback) return;

    const { data: referral, error: referralError } = await admin.rpc("cancel_referral_transaction", {
        p_transaction_id: transactionId,
        p_reason: reason,
    });
    if (referralError) throw new Error(`cancel_referral_transaction: ${referralError.message}`);

    const { data: topup, error: topupError } = isFull
        ? await admin.rpc("refund_topup_transaction", { p_transaction_id: transactionId, p_reason: reason })
        : await admin.rpc("review_topup_adjustment", {
            p_transaction_id: transactionId,
            p_reason: `partial_adjustment:${reason}`,
        });
    if (topupError) throw new Error(`topup adjustment: ${topupError.message}`);

    console.log(
        `billing adjustment txn=${transactionId} referral=${JSON.stringify(referral)} topup=${JSON.stringify(topup)}`,
    );
}

async function handleSubscription(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    eventId: string | null,
    eventOccurredAt: string | null,
): Promise<void> {
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

    if (!eventId || !eventOccurredAt) {
        console.warn("subscription event missing immutable event identity — skipping");
        return;
    }

    // Ordered and idempotent: the RPC ignores an event older than the one it has
    // already applied, so a Paddle redelivery cannot walk the status backwards.
    const { data: applied, error } = await admin.rpc("apply_paddle_subscription", {
        p_user_id:           userId,
        p_customer_id:       customerId,
        p_subscription_id:   subscriptionId,
        p_price_id:          priceId,
        p_paddle_status:     status,
        p_period_start:      periodStart,
        p_period_end:        periodEnd,
        p_event_id:          eventId,
        p_event_occurred_at: eventOccurredAt,
    });
    if (error) throw new Error(`apply_paddle_subscription: ${error.message}`);
    console.log(`subscription event user=${userId} status=${status} price=${priceId} applied=${applied === true}`);

    // A referrer collects waiting credit as soon as they are billable again, so
    // a resubscribe is also a payout opportunity.
    if (applied === true && status === "active") {
        try {
            await payoutDueRewards(admin, userId);
        } catch (err) {
            console.error(`reward payout error user=${userId}: ${err}`);
        }
    }
}

// Resolve provider-owned identity first. Checkout `custom_data` is only a
// bootstrap for the very first event, before a subscription row exists — trusting
// it afterwards would let a replayed checkout payload point at another account.
async function resolveUserId(
    admin: ReturnType<typeof adminClient>,
    data: Record<string, unknown>,
    subscriptionId: string,
    customerId: string | null,
): Promise<string | null> {
    let query = admin.from("subscriptions").select("user_id").limit(1);
    if (subscriptionId) query = query.eq("paddle_subscription_id", subscriptionId);
    else if (customerId) query = query.eq("paddle_customer_id", customerId);
    else {
        const custom = isObject(data.custom_data) ? data.custom_data : {};
        return nullableStr(custom.user_id);
    }

    const { data: row } = await query.maybeSingle();
    if (row?.user_id) return row.user_id;
    const custom = isObject(data.custom_data) ? data.custom_data : {};
    return nullableStr(custom.user_id);
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
    event_id?: unknown;
    event_type?: string;
    occurred_at?: unknown;
    data?: unknown;
}

function firstPriceId(items: unknown): string | null {
    if (!Array.isArray(items)) return null;
    const first = items[0];
    if (!isObject(first)) return null;
    if (isObject(first.price)) return nullableStr(first.price.id);
    return nullableStr(first.price_id);
}

function priceIds(items: unknown): string[] {
    if (!Array.isArray(items)) return [];
    return items.flatMap((item) => {
        if (!isObject(item)) return [];
        const id = isObject(item.price) ? nullableStr(item.price.id) : nullableStr(item.price_id);
        return id ? [id] : [];
    });
}

function str(value: unknown): string {
    return typeof value === "string" ? value : "";
}

function nullableStr(value: unknown): string | null {
    return typeof value === "string" && value.length > 0 ? value : null;
}
