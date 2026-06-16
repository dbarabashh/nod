// create-checkout — turns a signed-in user's plan choice into a Paddle-hosted
// checkout URL the macOS app opens in the browser.
//
// Why server-side (not Paddle.js in the app): Paddle.js is web-only and can't
// run in SwiftUI. So the app posts a `price_id` here with its Supabase JWT; we
// resolve the user from that JWT (never trust a client-supplied user id),
// create a Paddle transaction with `custom_data.user_id` so the webhook can
// later attribute the subscription, and return `checkout.url`.
//
// Request shape (POST /functions/v1/create-checkout):
//   Authorization: Bearer <supabase-access-token>
//   Body:          { "price_id": "pri_…" }
// Response:        { "url": "https://…/?_ptxn=txn_…" }
//
// Secrets (set via `supabase secrets set`, or a local --env-file):
//   PADDLE_API_KEY   — server-side API key (sandbox `apikey_…` or live)
//   PADDLE_API_BASE  — defaults to the sandbox host
//
// Deployed per-branch via git: the `develop` branch (sandbox secrets) and
// `main` (live secrets) each get their own copy from their git branch.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "../_shared/paddle.ts";

const PADDLE_API_KEY  = Deno.env.get("PADDLE_API_KEY");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

interface CheckoutRequest {
    price_id: string;
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

    let body: CheckoutRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }
    if (!body.price_id || typeof body.price_id !== "string") {
        return json({ error: "Missing 'price_id'" }, 400);
    }

    // One subscription per user. If they already have a live Paddle subscription,
    // a plan/cycle switch must UPDATE it in place — never spin up a second one
    // (which would double-bill). A new checkout is only for users with no active
    // subscription (trial, expired, or canceled).
    const admin = adminClient();
    const { data: sub } = await admin
        .from("subscriptions")
        .select("paddle_subscription_id, paddle_customer_id, status")
        .eq("user_id", user.id)
        .maybeSingle();

    // Any non-terminal Paddle subscription is changed IN PLACE — keying on the
    // subscription id (not a status whitelist) so a `trialing` or `paused`
    // subscription can't slip through and spawn a second one (double-bill).
    // Only canceled/expired fall through to a fresh checkout (resubscribe).
    const hasLiveSubscription = !!sub?.paddle_subscription_id
        && sub.status !== "canceled"
        && sub.status !== "expired";
    if (hasLiveSubscription) {
        const res = await fetch(`${PADDLE_API_BASE}/subscriptions/${sub.paddle_subscription_id}`, {
            method: "PATCH",
            headers: PADDLE_HEADERS,
            body: JSON.stringify({
                items: [{ price_id: body.price_id, quantity: 1 }],
                proration_billing_mode: "prorated_immediately",
            }),
        });
        const text = await res.text();
        if (!res.ok) {
            console.error(`paddle subscription update failed status=${res.status} body=${text.slice(0, 400)}`);
            return json({ error: "Plan change failed" }, 502);
        }
        console.log(`plan change user=${user.id} sub=${sub.paddle_subscription_id} price=${body.price_id}`);
        // No checkout needed — Paddle charges the card on file and fires
        // subscription.updated, which the webhook applies to our DB.
        return json({ updated: true }, 200);
    }

    // New subscription. Reuse the stored Paddle customer if we have one;
    // otherwise match-or-create by email so the checkout can skip its first
    // page. Customer lookup is best-effort — a failure just means the checkout
    // collects the email itself.
    let customerId: string | undefined = sub?.paddle_customer_id ?? undefined;
    if (!customerId && user.email) {
        try {
            customerId = await findOrCreateCustomer(user.email);
        } catch (err) {
            console.warn(`customer prefill skipped: ${err}`);
        }
    }

    const payload: Record<string, unknown> = {
        items: [{ price_id: body.price_id, quantity: 1 }],
        custom_data: { user_id: user.id },
        collection_mode: "automatic",
    };
    if (customerId) payload.customer_id = customerId;

    const res = await fetch(`${PADDLE_API_BASE}/transactions`, {
        method: "POST",
        headers: PADDLE_HEADERS,
        body: JSON.stringify(payload),
    });
    const text = await res.text();
    if (!res.ok) {
        console.error(`paddle create transaction failed status=${res.status} body=${text.slice(0, 400)}`);
        return json({ error: "Checkout creation failed" }, 502);
    }

    let url: string | undefined;
    try {
        url = JSON.parse(text)?.data?.checkout?.url;
    } catch {
        // fall through to the missing-url branch
    }
    if (!url) {
        // No checkout.url means no default payment link is configured in the
        // Paddle dashboard (Checkout settings) — the transaction exists but has
        // nowhere to be paid.
        console.error("paddle response had no data.checkout.url — set a default payment link");
        return json({ error: "No checkout URL — configure a default payment link in Paddle" }, 502);
    }

    console.log(`checkout user=${user.id} price=${body.price_id}`);
    return json({ url }, 200);
});

// Paddle has no upsert-by-email; list first, create only on a miss. Returns the
// customer id (`ctm_…`). Throws on a hard API error so the caller logs + omits.
async function findOrCreateCustomer(email: string): Promise<string | undefined> {
    const headers = PADDLE_HEADERS;

    const listRes = await fetch(`${PADDLE_API_BASE}/customers?email=${encodeURIComponent(email)}`, { headers });
    if (listRes.ok) {
        const existing = (await listRes.json())?.data?.[0]?.id;
        if (existing) return existing;
    }

    const createRes = await fetch(`${PADDLE_API_BASE}/customers`, {
        method: "POST",
        headers,
        body: JSON.stringify({ email }),
    });
    if (!createRes.ok) {
        // 409 = the customer already exists (race or archived). Re-list to grab
        // the id rather than failing the whole checkout.
        const retry = await fetch(`${PADDLE_API_BASE}/customers?email=${encodeURIComponent(email)}`, { headers });
        if (retry.ok) return (await retry.json())?.data?.[0]?.id;
        return undefined;
    }
    return (await createRes.json())?.data?.id;
}
