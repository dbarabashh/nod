// Top-up checkout — an explicit, non-recurring purchase of extra meeting hours
// or integration credits for the CURRENT billing period. Which pack, what it
// grants, and whether the person or their workspace is buying, is the
// catalogue's and the intent's business: this function only decides that the
// sku is one we sell.
//
// The order matters and is the whole point of this function:
//   1. Supabase mints an intent that pins the period, the included allowance and
//      the subscription this purchase belongs to.
//   2. Paddle creates the transaction.
//   3. The intent is bound to that transaction id before a payable URL is
//      returned.
// A purchase that cannot be tied back to an intent is never fulfilled
// automatically — `apply_topup_purchase` routes it to reconciliation instead.
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { isObject, json } from "../_shared/http.ts";
import { eventPlan } from "../_shared/product-events.ts";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "../_shared/paddle.ts";

const PADDLE_API_KEY = Deno.env.get("PADDLE_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

interface TopupCheckoutRequest {
    sku: string;
    /// Where the person pressed the button. Older clients send nothing and
    /// only ever bought from the allowance gate in the notch.
    surface?: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!PADDLE_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: PADDLE_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    let body: TopupCheckoutRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }
    // Which packs exist is the catalogue's answer, not a list kept here:
    // `create_topup_checkout_intent` resolves the sku against `plan_prices` and
    // refuses anything that is not an active, purchasable top-up.
    if (typeof body.sku !== "string" || body.sku.length === 0 || body.sku.length > 64) {
        return json({ error: "invalid_topup_sku" }, 422);
    }

    const admin = adminClient();
    const { data: intent, error: intentError } = await admin.rpc("create_topup_checkout_intent", {
        p_user_id: user.id,
        p_sku: body.sku,
    });
    if (intentError || !isObject(intent) || intent.created !== true) {
        const code = isObject(intent) && typeof intent.error === "string" ? intent.error : "topup_unavailable";
        if (intentError) console.error(`create_topup_checkout_intent failed user=${user.id}: ${intentError.message}`);
        // `topup_unconfigured` is our problem (no real price id yet); everything
        // else is a legitimate "not for this account right now".
        return json({ error: code }, code === "topup_unconfigured" ? 503 : 422);
    }
    const intentId = typeof intent.intent_id === "string" ? intent.intent_id : "";
    const priceId = typeof intent.paddle_price_id === "string" ? intent.paddle_price_id : "";
    if (!intentId || !priceId) return json({ error: "topup_unavailable" }, 503);

    // A workspace pack is paid by the workspace's Paddle customer, so it lands
    // on the same invoices as its seats; a personal one by the person's own.
    const orgId = typeof intent.org_id === "string" ? intent.org_id : null;
    const { data: subscription } = orgId
        ? await admin.from("org_subscriptions").select("paddle_customer_id").eq("org_id", orgId).maybeSingle()
        : await admin.from("subscriptions").select("paddle_customer_id").eq("user_id", user.id).maybeSingle();
    let customerId = typeof subscription?.paddle_customer_id === "string"
        ? subscription.paddle_customer_id
        : undefined;
    if (!customerId && user.email) {
        try {
            customerId = await findOrCreateCustomer(user.email);
        } catch (err) {
            console.warn(`customer prefill skipped: ${err}`);
        }
    }

    const payload: Record<string, unknown> = {
        items: [{ price_id: priceId, quantity: 1 }],
        custom_data: {
            user_id: user.id,
            purchase_type: "starter_topup",
            sku: body.sku,
            topup_intent_id: intentId,
            // Marks the transaction as the workspace's for the webhook, which
            // then books no personal conversion against the buyer.
            ...(orgId ? { org_id: orgId } : {}),
        },
        collection_mode: "automatic",
    };
    if (customerId) payload.customer_id = customerId;

    const response = await fetch(`${PADDLE_API_BASE}/transactions`, {
        method: "POST",
        headers: PADDLE_HEADERS,
        body: JSON.stringify(payload),
    });
    const text = await response.text();
    if (!response.ok) {
        await admin.rpc("cancel_topup_checkout_intent", {
            p_intent_id: intentId,
            p_reason: `paddle_create_failed:${response.status}`,
        });
        console.error(`paddle top-up transaction failed status=${response.status} body=${text.slice(0, 400)}`);
        return json({ error: "topup_checkout_failed" }, 502);
    }

    let url = "";
    let transactionId = "";
    try {
        const transaction = JSON.parse(text)?.data;
        url = typeof transaction?.checkout?.url === "string" ? transaction.checkout.url : "";
        transactionId = typeof transaction?.id === "string" ? transaction.id : "";
    } catch {
        url = "";
    }

    // A transaction that exists must be recorded even when we cannot return a
    // URL: the customer may still pay it from Paddle, and fulfilment needs the
    // link back to this intent.
    if (transactionId) {
        const { data: attached, error: attachError } = await admin.rpc("attach_topup_checkout_transaction", {
            p_intent_id: intentId,
            p_transaction_id: transactionId,
        });
        if (attachError || attached !== true) {
            console.error(`top-up intent attach failed intent=${intentId} txn=${transactionId}: ${attachError?.message ?? "not attached"}`);
            return json({ error: "topup_checkout_unavailable" }, 502);
        }
    }
    if (!url || !transactionId) {
        console.error("paddle top-up response had no checkout url or id — check the default payment link");
        return json({ error: "topup_checkout_unavailable" }, 502);
    }

    const fromSettings = body.surface === "settings";
    const { error: telemetryError } = await admin.rpc("record_server_product_event", {
        p_user_id: user.id,
        p_event: "topup_checkout_started",
        p_properties: {
            surface: fromSettings ? "settings" : "capture",
            entry_point: fromSettings ? "settings" : "notch",
            plan: eventPlan(intent.plan),
            billing: "one_time",
            outcome: "success",
        },
    });
    if (telemetryError) console.warn(`top-up checkout telemetry failed: ${telemetryError.message}`);

    console.log(`top-up checkout user=${user.id} intent=${intentId} txn=${transactionId}`);
    return json({ url }, 200);
});

async function findOrCreateCustomer(email: string): Promise<string | undefined> {
    const listed = await fetch(`${PADDLE_API_BASE}/customers?email=${encodeURIComponent(email)}`, {
        headers: PADDLE_HEADERS,
    });
    if (listed.ok) {
        const existing = (await listed.json())?.data?.[0]?.id;
        if (typeof existing === "string") return existing;
    }
    const created = await fetch(`${PADDLE_API_BASE}/customers`, {
        method: "POST",
        headers: PADDLE_HEADERS,
        body: JSON.stringify({ email }),
    });
    if (created.ok) {
        const id = (await created.json())?.data?.id;
        return typeof id === "string" ? id : undefined;
    }
    return undefined;
}
