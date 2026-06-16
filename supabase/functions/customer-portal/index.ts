// customer-portal — opens Paddle's hosted customer portal for the signed-in
// user, where they cancel, update their card, or fetch invoices. As Merchant of
// Record, Paddle owns this surface (and the refund/tax/legal logic behind it),
// so the app never builds its own cancellation UI.
//
// Request shape (POST /functions/v1/customer-portal):
//   Authorization: Bearer <supabase-access-token>
// Response:        { "url": "https://…paddle portal overview…" }
//
// We resolve the user from their JWT, look up their stored `paddle_customer_id`
// (written by the webhook on subscription.created), then ask Paddle for a portal
// session scoped to their subscription.
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "../_shared/paddle.ts";

const PADDLE_API_KEY  = Deno.env.get("PADDLE_API_KEY");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    if (!PADDLE_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: PADDLE_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    const admin = adminClient();
    const { data: sub } = await admin
        .from("subscriptions")
        .select("paddle_customer_id, paddle_subscription_id")
        .eq("user_id", user.id)
        .maybeSingle();

    const customerId = sub?.paddle_customer_id;
    if (!customerId) {
        // Trial / never-paid accounts have no Paddle customer to manage.
        return json({ error: "no_paddle_customer" }, 404);
    }

    const body = sub?.paddle_subscription_id
        ? { subscription_ids: [sub.paddle_subscription_id] }
        : {};

    const res = await fetch(`${PADDLE_API_BASE}/customers/${customerId}/portal-sessions`, {
        method: "POST",
        headers: PADDLE_HEADERS,
        body: JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) {
        console.error(`paddle portal-session failed status=${res.status} body=${text.slice(0, 400)}`);
        return json({ error: "Portal creation failed" }, 502);
    }

    let url: string | undefined;
    try {
        url = JSON.parse(text)?.data?.urls?.general?.overview;
    } catch {
        // fall through
    }
    if (!url) {
        console.error("paddle portal response had no urls.general.overview");
        return json({ error: "No portal URL" }, 502);
    }

    console.log(`portal user=${user.id} customer=${customerId}`);
    return json({ url }, 200);
});
