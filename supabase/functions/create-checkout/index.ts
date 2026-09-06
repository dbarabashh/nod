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
//   Body:          { "price_id": "pri_…" }            personal plan
//                  { "price_id": "pri_…", "seats": 5 } workspace plan
// Response:        { "url": "https://…/?_ptxn=txn_…" }
//
// Workspace plans (`plan_prices.plan = 'teams'`) buy seats for the caller's
// active organization rather than for the caller. The organization is read from
// the server (`profiles.active_org_id`), never from the request, and only an
// owner or admin of it may pay. Seats become the Paddle item quantity and the
// webhook routes the subscription to `org_subscriptions` via
// `custom_data.org_id`.
//
// Referral (NOD-22): the body may carry an optional `ref` — the referrer's
// stable code. We always stamp it into `custom_data` (so the webhook can credit
// the referrer once the friend pays), but the friend's −50% Paddle discount is
// attached ONLY when the chosen price is a MONTHLY cycle. On a yearly price
// "50% off 1 billing period" would be 50% off a whole year — see the hard
// constraint in NOD-22. The discount itself is a single static Paddle discount
// reused across all referred checkouts; its id is a per-branch secret.
//
// Secrets (set via `supabase secrets set`, or a local --env-file):
//   PADDLE_API_KEY              — server-side API key (sandbox `apikey_…` or live)
//   PADDLE_API_BASE             — defaults to the sandbox host
//   PADDLE_REFERRAL_DISCOUNT_ID — static "−50% / recurring 1 period" discount
//                                 (`dsc_…`), set PER BRANCH (sandbox vs live).
//                                 Absent → referrals still attribute, no discount.
//
// Deployed per-branch via git: the `develop` branch (sandbox secrets) and
// `main` (live secrets) each get their own copy from their git branch.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { eventPlan } from "../_shared/product-events.ts";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "../_shared/paddle.ts";

const PADDLE_API_KEY              = Deno.env.get("PADDLE_API_KEY");
const PADDLE_REFERRAL_DISCOUNT_ID = Deno.env.get("PADDLE_REFERRAL_DISCOUNT_ID");
const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

interface CheckoutRequest {
    price_id: string;
    ref?: string;
    offer?: "winback";
    /** Workspace plans only: how many seats the organization is buying. */
    seats?: number;
}

interface PriceRow {
    plan: string;
    billing_cycle: string;
    kind: string;
    active: boolean;
    available_for_new_checkout: boolean;
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

    const ref = typeof body.ref === "string"
        ? body.ref.trim().toUpperCase() || undefined
        : undefined;
    const offer = body.offer === "winback" ? body.offer : undefined;
    if (body.offer !== undefined && !offer) return json({ error: "offer_not_eligible" }, 422);
    if (ref && offer) return json({ error: "offer_not_eligible" }, 422);

    // One subscription per user. If they already have a live Paddle subscription,
    // a plan/cycle switch must UPDATE it in place — never spin up a second one
    // (which would double-bill). A new checkout is only for users with no active
    // subscription (trial, expired, or canceled).
    const admin = adminClient();
    const { data: rawPrice, error: priceError } = await admin
        .from("plan_prices")
        .select("plan, billing_cycle, kind, active, available_for_new_checkout")
        .eq("paddle_price_id", body.price_id)
        .maybeSingle();
    const price = rawPrice as PriceRow | null;
    // The client may only buy what the catalog currently offers, so a dark or
    // superseded price can never be checked out by a patched or stale build.
    if (priceError || !price || price.kind !== "subscription" || !price.active || !price.available_for_new_checkout) {
        return json({ error: "offer_not_eligible" }, 422);
    }
    if (body.price_id.startsWith("pri_REPLACE_")) {
        console.error(`checkout blocked for placeholder price=${body.price_id}`);
        return json({ error: "pricing_unconfigured" }, 503);
    }
    if (offer && (price.billing_cycle !== "monthly" || !["starter", "pro"].includes(price.plan))) {
        return json({ error: "offer_not_eligible" }, 422);
    }

    // A workspace plan is bought for an organization, so who is paying and what
    // is already subscribed are both different questions from the personal case.
    const isWorkspacePlan = price.plan === "teams";
    let orgId: string | null = null;
    let seats = 1;
    if (isWorkspacePlan) {
        // Referral and win-back are first-payer offers on a personal plan. Neither
        // has a defined meaning against a seat count, so neither is accepted.
        if (ref || offer) return json({ error: "offer_not_eligible" }, 422);

        seats = typeof body.seats === "number" ? body.seats : NaN;
        if (!Number.isInteger(seats) || seats < 1 || seats > 500) {
            return json({ error: "seats_invalid" }, 422);
        }

        const { data: profile } = await admin
            .from("profiles")
            .select("active_org_id")
            .eq("user_id", user.id)
            .maybeSingle();
        orgId = (profile?.active_org_id as string | null) ?? null;
        if (!orgId) return json({ error: "no_active_workspace" }, 422);

        const { data: member } = await admin
            .from("org_members")
            .select("role, status")
            .eq("org_id", orgId)
            .eq("user_id", user.id)
            .maybeSingle();
        if (!member || member.status !== "active" || !["owner", "admin"].includes(member.role as string)) {
            return json({ error: "not_a_workspace_admin" }, 403);
        }

        // Buying fewer seats than there are people would silently uncover
        // colleagues who are working today, so it is refused rather than applied.
        const { count, error: countError } = await admin
            .from("org_members")
            .select("id", { count: "exact", head: true })
            .eq("org_id", orgId)
            .eq("status", "active");
        if (countError) {
            console.error(`workspace member count failed org=${orgId}: ${countError.message}`);
            return json({ error: "Checkout creation failed" }, 502);
        }
        if ((count ?? 0) > seats) return json({ error: "seats_below_members" }, 422);
    }

    const { data: sub } = isWorkspacePlan
        ? await admin
            .from("org_subscriptions")
            .select("paddle_subscription_id, paddle_customer_id, status")
            .eq("org_id", orgId)
            .maybeSingle()
        : await admin
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
        // The offer is for a first-ever payer, and a plan change is not one.
        if (ref) return json({ error: "already_paid" }, 422);
        const res = await fetch(`${PADDLE_API_BASE}/subscriptions/${sub.paddle_subscription_id}`, {
            method: "PATCH",
            headers: PADDLE_HEADERS,
            body: JSON.stringify({
                items: [{ price_id: body.price_id, quantity: seats }],
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

    // Somebody a workspace already covers gains nothing from a NEW personal plan —
    // `resolve_entitlement` keeps resolving them to the organization — so selling
    // them one takes money for nothing. Refused here rather than in the paywall,
    // because every already-released client still offers it. Changing a personal
    // subscription they are already being charged for is a different act and is
    // handled above, so this sits after the in-place path deliberately.
    if (!isWorkspacePlan) {
        const { data: entitlement, error: entitlementError } = await admin
            .rpc("resolve_entitlement", { p_user_id: user.id });
        if (entitlementError) {
            console.error(`entitlement lookup failed user=${user.id}: ${entitlementError.message}`);
            return json({ error: "Checkout creation failed" }, 502);
        }
        if (isObject(entitlement) && entitlement.payer === "organization") {
            return json({ error: "covered_by_workspace" }, 422);
        }
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

    // Referral eligibility is decided here, before Paddle is called, and it
    // fails closed: a code we cannot fully verify gets no discount and no
    // checkout, rather than a discount now and a dispute later.
    let referralId: string | undefined;
    if (ref) {
        if (!PADDLE_REFERRAL_DISCOUNT_ID) {
            console.error("referral checkout blocked: PADDLE_REFERRAL_DISCOUNT_ID not set");
            return json({ error: "referral_unavailable" }, 503);
        }
        if (!customerId) {
            console.error(`referral checkout blocked: Paddle customer unavailable user=${user.id}`);
            return json({ error: "referral_unavailable" }, 503);
        }
        // Regional pricing and the referral discount must not stack, and Paddle
        // applies both silently if we let them.
        const priceStatus = await referralPriceStatus(body.price_id);
        if (priceStatus === "overridden") return json({ error: "offer_not_eligible" }, 422);
        if (priceStatus !== "eligible") return json({ error: "referral_unavailable" }, 503);

        const payerStatus = await paddleCustomerPaymentStatus(customerId);
        if (payerStatus === "paid") return json({ error: "already_paid" }, 422);
        if (payerStatus !== "new") return json({ error: "referral_unavailable" }, 503);

        const { data: verdict, error: referralError } = await admin.rpc("reserve_referral_attribution", {
            p_referee_user_id: user.id,
            p_code: ref,
            p_price_id: body.price_id,
            p_paddle_customer_id: customerId,
        });
        if (referralError || !isObject(verdict)) {
            console.error(`referral validation failed user=${user.id}: ${referralError?.message ?? "unexpected verdict"}`);
            return json({ error: "referral_unavailable" }, 503);
        }
        if (verdict.eligible !== true) {
            return json({ error: typeof verdict.error === "string" ? verdict.error : "invalid_referral" }, 422);
        }
        referralId = typeof verdict.referral_id === "string" ? verdict.referral_id : undefined;
    }

    let offerClaimId: string | undefined;
    if (offer) {
        const { data: claimId, error: claimError } = await admin.rpc("reserve_email_offer_claim", {
            p_user_id: user.id,
            p_offer_key: offer,
        });
        if (claimError || typeof claimId !== "string") {
            return json({ error: "offer_not_eligible" }, 422);
        }
        offerClaimId = claimId;
    }

    const customData: Record<string, unknown> = { user_id: user.id };
    // The webhook routes on this: an event carrying an org_id belongs to the
    // organization's subscription, not to the person who happened to pay.
    if (orgId) {
        customData.org_id = orgId;
        customData.purchased_by = user.id;
    }
    // The reservation id, not the raw code: the webhook resolves the referral
    // from our own row, so nothing about the reward depends on client input.
    if (referralId) customData.referral_id = referralId;
    if (offerClaimId) customData.offer_claim_id = offerClaimId;

    const payload: Record<string, unknown> = {
        items: [{ price_id: body.price_id, quantity: seats }],
        custom_data: customData,
        collection_mode: "automatic",
    };
    if (customerId) payload.customer_id = customerId;
    if (referralId) {
        payload.discount_id = PADDLE_REFERRAL_DISCOUNT_ID;
        console.log(`referral discount applied user=${user.id} referral=${referralId}`);
    } else if (offerClaimId) {
        payload.discount = {
            type: "percentage",
            amount: "15",
            description: "Nod win-back offer",
            recur: false,
            restrict_to: [body.price_id],
        };
    }

    const res = await fetch(`${PADDLE_API_BASE}/transactions`, {
        method: "POST",
        headers: PADDLE_HEADERS,
        body: JSON.stringify(payload),
    });
    const text = await res.text();
    if (!res.ok) {
        if (offerClaimId) {
            await admin.rpc("release_email_offer_claim", { p_claim_id: offerClaimId, p_user_id: user.id });
        }
        console.error(`paddle create transaction failed status=${res.status} body=${text.slice(0, 400)}`);
        return json({ error: "Checkout creation failed" }, 502);
    }

    let url: string | undefined;
    let transactionId: string | undefined;
    try {
        const transaction = JSON.parse(text)?.data;
        url = transaction?.checkout?.url;
        transactionId = typeof transaction?.id === "string" ? transaction.id : undefined;
    } catch {
        // fall through to the missing-url branch
    }
    if (!url) {
        if (offerClaimId) {
            await admin.rpc("release_email_offer_claim", { p_claim_id: offerClaimId, p_user_id: user.id });
        }
        // No checkout.url means no default payment link is configured in the
        // Paddle dashboard (Checkout settings) — the transaction exists but has
        // nowhere to be paid.
        console.error("paddle response had no data.checkout.url — set a default payment link");
        return json({ error: "No checkout URL — configure a default payment link in Paddle" }, 502);
    }

    // Bind the reservation to the transaction that will actually be paid BEFORE
    // handing out a payable URL. If two checkouts race, only the bound one can
    // ever activate a referral — and an unbindable one is not payable at all.
    if (referralId) {
        if (!transactionId) return json({ error: "referral_unavailable" }, 503);
        const { data: bound, error: bindError } = await admin.rpc("bind_referral_checkout_transaction", {
            p_referral_id: referralId,
            p_referee_user_id: user.id,
            p_transaction_id: transactionId,
        });
        if (bindError || bound !== true) {
            console.error(`referral checkout bind failed referral=${referralId} txn=${transactionId}: ${bindError?.message ?? "not bound"}`);
            return json({ error: "referral_unavailable" }, 503);
        }
    }
    if (offerClaimId) {
        if (!transactionId) {
            await admin.rpc("release_email_offer_claim", { p_claim_id: offerClaimId, p_user_id: user.id });
            return json({ error: "offer_unavailable" }, 503);
        }
        const { data: bound, error: bindError } = await admin.rpc("bind_email_offer_transaction", {
            p_claim_id: offerClaimId,
            p_user_id: user.id,
            p_transaction_id: transactionId,
        });
        if (bindError || bound !== true) {
            console.error(`winback checkout bind failed claim=${offerClaimId} txn=${transactionId}`);
            return json({ error: "offer_unavailable" }, 503);
        }
    }

    const plan = eventPlan(price.plan);
    const billing = price.billing_cycle === "monthly" || price.billing_cycle === "yearly"
        ? price.billing_cycle
        : "unknown";
    const { error: telemetryError } = await admin.from("product_events").insert({
        id: crypto.randomUUID(),
        user_id: user.id,
        occurred_at: new Date().toISOString(),
        event: "checkout_started",
        platform: "server",
        app_version: "server",
        properties: { surface: "paywall", outcome: "success", plan, billing },
    });
    if (telemetryError) {
        console.warn(`checkout telemetry failed: ${telemetryError.message}`);
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

// A price with per-country overrides is already discounted for that customer, so
// stacking the referral 50% on top is a giveaway we never agreed to. Unknown
// means unknown: we refuse rather than guess.
async function referralPriceStatus(priceId: string): Promise<"eligible" | "overridden" | "unavailable"> {
    try {
        const response = await fetch(`${PADDLE_API_BASE}/prices/${encodeURIComponent(priceId)}`, {
            headers: PADDLE_HEADERS,
        });
        if (!response.ok) {
            console.error(`referral price preflight failed price=${priceId} status=${response.status}`);
            return "unavailable";
        }
        const payload = await response.json();
        const overrides = isObject(payload?.data) ? payload.data.unit_price_overrides : undefined;
        if (!Array.isArray(overrides)) {
            console.error(`referral price preflight missing overrides array price=${priceId}`);
            return "unavailable";
        }
        return overrides.length === 0 ? "eligible" : "overridden";
    } catch (err) {
        console.error(`referral price preflight threw price=${priceId}: ${err}`);
        return "unavailable";
    }
}

// Paddle is the authority on whether this customer ever completed a payment —
// including under a different Nod account with the same card and email.
async function paddleCustomerPaymentStatus(customerId: string): Promise<"new" | "paid" | "unavailable"> {
    try {
        const params = new URLSearchParams({ customer_id: customerId, status: "completed", per_page: "1" });
        const response = await fetch(`${PADDLE_API_BASE}/transactions?${params}`, { headers: PADDLE_HEADERS });
        if (!response.ok) {
            console.error(`referral payer-history preflight failed customer=${customerId} status=${response.status}`);
            return "unavailable";
        }
        const payload = await response.json();
        if (!Array.isArray(payload?.data)) return "unavailable";
        return payload.data.length > 0 ? "paid" : "new";
    } catch (err) {
        console.error(`referral payer-history preflight threw customer=${customerId}: ${err}`);
        return "unavailable";
    }
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
