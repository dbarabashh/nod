// Applying a reward means moving a subscription's next billing date out. That is
// one provider write we must never make twice, so the shape here is: observe,
// claim against what we observed, write, then reconcile against what Paddle now
// reports. Every branch ends in `reconcile_reward_payout`, which is idempotent.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "./paddle.ts";

const PADDLE_API_KEY = Deno.env.get("PADDLE_API_KEY");

export async function payoutDueRewards(admin: SupabaseClient, userId: string): Promise<boolean> {
    if (!PADDLE_API_KEY) {
        // Without the key, PADDLE_HEADERS sends "Bearer undefined" and the base
        // falls back to sandbox — never let that touch a real subscription.
        console.error("reward payout skipped: PADDLE_API_KEY not set");
        return false;
    }

    const subscriptionId = await payoutSubscriptionId(admin, userId);
    if (!subscriptionId) return false;

    let observed = await fetchNextBilledAt(subscriptionId);
    if (!observed) return false;

    const { data: rawClaim, error: claimError } = await admin.rpc("claim_reward_payout", {
        p_beneficiary_user_id: userId,
        p_base_next_billed_at: observed,
    });
    if (claimError || !isObject(rawClaim)) {
        console.error(`claim_reward_payout failed user=${userId}: ${claimError?.message ?? "unexpected response"}`);
        return false;
    }
    if (Number(rawClaim.count ?? 0) <= 0 && rawClaim.status !== "reconciliation_required") {
        return true;
    }

    const payoutId = stringValue(rawClaim.payout_id);
    const claimedSubscriptionId = stringValue(rawClaim.paddle_subscription_id);
    const base = stringValue(rawClaim.base_next_billed_at);
    const target = stringValue(rawClaim.target_next_billed_at);
    if (!payoutId || !claimedSubscriptionId || !base || !target) {
        console.error(`reward payout claim missing fields user=${userId}`);
        return false;
    }

    // The claim may be an older one we are resuming, possibly against a
    // subscription that has since changed.
    if (claimedSubscriptionId !== subscriptionId) {
        const reobserved = await fetchNextBilledAt(claimedSubscriptionId);
        if (!reobserved) {
            console.error(`reward payout subscription unreadable payout=${payoutId} stored=${claimedSubscriptionId}`);
            return false;
        }
        observed = reobserved;
    }

    if (rawClaim.status === "reconciliation_required") {
        const action = await reconcile(admin, payoutId, observed, "resuming an unresolved payout");
        return action === "applied" || action === "canceled";
    }

    // Already at the target: a previous attempt succeeded and we never saw the
    // answer. Record it as applied rather than shifting the date again.
    if (sameInstant(observed, target)) {
        await reconcile(admin, payoutId, observed, null);
        return true;
    }
    if (!sameInstant(observed, base)) {
        await reconcile(admin, payoutId, observed, "Paddle billing date matched neither payout base nor target");
        return false;
    }

    try {
        const response = await fetch(`${PADDLE_API_BASE}/subscriptions/${encodeURIComponent(claimedSubscriptionId)}`, {
            method: "PATCH",
            headers: PADDLE_HEADERS,
            body: JSON.stringify({ next_billed_at: target, proration_billing_mode: "do_not_bill" }),
        });
        if (!response.ok) {
            const error = `Paddle payout update failed status=${response.status} body=${(await response.text()).slice(0, 300)}`;
            console.error(error);
            // Nothing moved, so the credits go back in the queue.
            await reconcile(admin, payoutId, base, error);
            return false;
        }
        const updated = stringValue((await response.json())?.data?.next_billed_at) || target;
        return (await reconcile(admin, payoutId, updated, null)) === "applied";
    } catch (err) {
        // The write may or may not have landed. Leave the claim pending and let
        // the next run observe the truth instead of guessing.
        console.error(`Paddle payout update ambiguous payout=${payoutId}: ${err}`);
        return false;
    }
}

// Prefer the subscription an unresolved payout was claimed against; otherwise
// the user's current active one.
async function payoutSubscriptionId(admin: SupabaseClient, userId: string): Promise<string> {
    const { data: existing, error: existingError } = await admin
        .from("reward_payouts")
        .select("paddle_subscription_id")
        .eq("beneficiary_user_id", userId)
        .in("status", ["pending", "reconciliation_required"])
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();
    if (existingError) return "";
    const claimed = stringValue(existing?.paddle_subscription_id);
    if (claimed) return claimed;

    const { data: subscription, error: subscriptionError } = await admin
        .from("subscriptions")
        .select("paddle_subscription_id, status")
        .eq("user_id", userId)
        .maybeSingle();
    if (subscriptionError || subscription?.status !== "active") return "";
    return stringValue(subscription?.paddle_subscription_id);
}

async function fetchNextBilledAt(subscriptionId: string): Promise<string | null> {
    try {
        const response = await fetch(`${PADDLE_API_BASE}/subscriptions/${encodeURIComponent(subscriptionId)}`, {
            headers: PADDLE_HEADERS,
        });
        if (!response.ok) {
            console.error(`Paddle subscription fetch failed status=${response.status}`);
            return null;
        }
        const value = (await response.json())?.data?.next_billed_at;
        return typeof value === "string" ? value : null;
    } catch (err) {
        console.error(`Paddle subscription fetch threw: ${err}`);
        return null;
    }
}

async function reconcile(
    admin: SupabaseClient,
    payoutId: string,
    observed: string,
    error: string | null,
): Promise<string> {
    const { data, error: rpcError } = await admin.rpc("reconcile_reward_payout", {
        p_payout_id: payoutId,
        p_observed_next_billed_at: observed,
        p_error: error,
    });
    if (rpcError || !isObject(data)) {
        console.error(`reconcile_reward_payout failed payout=${payoutId}: ${rpcError?.message ?? "unexpected response"}`);
        return "error";
    }
    return stringValue(data.action);
}

// Paddle echoes timestamps in its own format, so compare instants, not strings.
function sameInstant(left: string, right: string): boolean {
    const leftMs = Date.parse(left);
    const rightMs = Date.parse(right);
    return Number.isFinite(leftMs) && Number.isFinite(rightMs) && leftMs === rightMs;
}

function stringValue(value: unknown): string {
    return typeof value === "string" ? value : "";
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
