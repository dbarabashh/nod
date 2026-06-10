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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const PADDLE_API_KEY  = Deno.env.get("PADDLE_API_KEY");
// The environment is baked into the key (`pdl_live_…` vs `pdl_sdbx_…`), so the
// API host follows it automatically — flipping sandbox↔live is a single secret
// swap (PADDLE_API_KEY), nothing else. PADDLE_API_BASE stays as an override.
const PADDLE_API_BASE = Deno.env.get("PADDLE_API_BASE")
    ?? (PADDLE_API_KEY?.startsWith("pdl_live_") ? "https://api.paddle.com" : "https://sandbox-api.paddle.com");
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");

interface CheckoutRequest {
    price_id: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    if (!PADDLE_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
        console.error("missing env: PADDLE_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY");
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

    let body: CheckoutRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }
    if (!body.price_id || typeof body.price_id !== "string") {
        return json({ error: "Missing 'price_id'" }, 400);
    }

    // Best-effort customer prefill: matching the user's email to (or creating)
    // a Paddle customer lets the checkout skip its first page. Any failure here
    // is non-fatal — we just open a checkout that collects the email instead.
    let customerId: string | undefined;
    if (user.email) {
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
        headers: {
            "Authorization": `Bearer ${PADDLE_API_KEY}`,
            "Content-Type": "application/json",
            "Paddle-Version": "1",
        },
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
    const headers = {
        "Authorization": `Bearer ${PADDLE_API_KEY}`,
        "Content-Type": "application/json",
        "Paddle-Version": "1",
    };

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

function json(body: unknown, status: number): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}
