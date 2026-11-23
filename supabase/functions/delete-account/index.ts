// delete-account — GDPR Right to Erasure (Art. 17). Permanently deletes the
// signed-in user's account and every row of their personal data.
//
// Request shape (POST /functions/v1/delete-account):
//   Authorization: Bearer <supabase-access-token>
// Response:        { "deleted": true }
//
// How the erasure is complete in one call:
//   - Every personal-data table FKs `auth.users(id)` with ON DELETE CASCADE
//     (meetings → transcripts/chat_messages/session_embeddings/meeting_entities/
//     meeting_labels/meeting_shares, plus profiles, entities, labels,
//     user_devices, usage_events, subscriptions, usage_credits). So deleting the
//     auth user removes all of it server-side, in-region, atomically.
//   - The ONE exception is `consent_acknowledgements` (ON DELETE SET NULL): its
//     rows are an immutable legal-defence audit trail, so they survive but are
//     orphaned — `user_id` is nulled and they're no longer resolvable to a
//     person. This matches Privacy Policy § 7.
//   - If the user has a live Paddle subscription we cancel it first (best
//     effort) so an erased account is never billed again. Paddle, as Merchant
//     of Record, retains its own billing/tax records independently.
//   - Organizations and teams the user created reference `auth.users` ON DELETE
//     RESTRICT, so `release_what_a_user_made` hands each one to another member
//     or, when it has none, deletes it before the auth user goes. That commits
//     on its own: should `deleteUser` then fail, the handovers and deletions
//     stand and a retry finds nothing left to release. An organization with no
//     other member that still holds someone else's data stops the erasure with
//     409 `org_has_member_data` before anything changes.
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { isObject, json } from "../_shared/http.ts";
import { PADDLE_API_BASE, PADDLE_HEADERS } from "../_shared/paddle.ts";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    const admin = adminClient();

    const released = await releaseWhatTheUserMade(admin, user.id);
    if (released instanceof Response) return released;

    // Best-effort: cancel any live Paddle subscription so the erased account is
    // never charged again. A failure here must NOT block erasure — the user's
    // right to be deleted outranks our billing cleanup, which we can reconcile
    // from Paddle's own dashboard if needed.
    const { data: sub } = await admin
        .from("subscriptions")
        .select("paddle_subscription_id, status")
        .eq("user_id", user.id)
        .maybeSingle();

    const hasLiveSubscription = !!sub?.paddle_subscription_id
        && sub.status !== "canceled"
        && sub.status !== "expired";
    if (hasLiveSubscription) {
        await cancelPaddleSubscription(sub.paddle_subscription_id, `user=${user.id}`);
    }
    for (const org of released.deletedOrgs) {
        if (org.paddleSubscriptionId) await cancelPaddleSubscription(org.paddleSubscriptionId, `org=${org.id}`);
        await removeOrgLogos(admin, org.id);
    }
    for (const workspace of released.cancelSubscriptions) {
        await cancelPaddleSubscription(workspace.paddleSubscriptionId, `org=${workspace.orgId}`, workspace.effectiveFrom);
    }

    // The cascade lives in the FK constraints — deleting the auth user erases
    // every dependent row. `shouldSoftDelete: false` makes it a hard delete in
    // auth.users too (no recoverable banned-user shell left behind).
    const { error } = await admin.auth.admin.deleteUser(user.id, false);
    if (error) {
        console.error(
            `deleteUser failed user=${user.id} after releasing deleted_orgs=${released.deletedOrgs.length}: ${error.message}`,
        );
        return json({ error: "Deletion failed" }, 502);
    }

    console.log(`account erased user=${user.id}`);
    return json({ deleted: true }, 200);
});

type DeletedOrg = { id: string; paddleSubscriptionId: string | null };
type CancelTiming = "immediately" | "next_billing_period";
type WorkspaceSubscription = { orgId: string; paddleSubscriptionId: string; effectiveFrom: CancelTiming };
type Released = { deletedOrgs: DeletedOrg[]; cancelSubscriptions: WorkspaceSubscription[] };

async function releaseWhatTheUserMade(
    admin: SupabaseClient,
    userId: string,
): Promise<Released | Response> {
    const { data, error } = await admin.rpc("release_what_a_user_made", { p_user: userId });
    if (error) {
        // Deployed ahead of its migration: behave exactly like the build before
        // it rather than refusing every erasure until the migration lands.
        if (error.code === "PGRST202") {
            console.warn("release_what_a_user_made missing; migration not applied yet");
            return { deletedOrgs: [], cancelSubscriptions: [] };
        }
        if (error.hint === "org_has_member_data") {
            console.warn(`erasure blocked user=${userId}: ${error.message}`);
            return json({ error: "org_has_member_data", organization: error.details ?? null }, 409);
        }
        console.error(`release_what_a_user_made failed user=${userId}: ${error.message}`);
        return json({ error: "Deletion failed" }, 502);
    }

    const deletedOrgs: DeletedOrg[] = [];
    const rows = isObject(data) && Array.isArray(data.deleted_orgs) ? data.deleted_orgs : [];
    for (const row of rows) {
        if (!isObject(row) || typeof row.id !== "string") continue;
        const subscription = row.paddle_subscription_id;
        deletedOrgs.push({
            id: row.id,
            paddleSubscriptionId: typeof subscription === "string" ? subscription : null,
        });
    }
    const cancelSubscriptions: WorkspaceSubscription[] = [];
    const cancelRows = isObject(data) && Array.isArray(data.cancel_subscriptions) ? data.cancel_subscriptions : [];
    for (const row of cancelRows) {
        if (!isObject(row) || typeof row.org_id !== "string" || typeof row.paddle_subscription_id !== "string") continue;
        cancelSubscriptions.push({
            orgId: row.org_id,
            paddleSubscriptionId: row.paddle_subscription_id,
            effectiveFrom: row.effective_from === "immediately" ? "immediately" : "next_billing_period",
        });
    }
    console.log(
        `released user=${userId} deleted_orgs=${deletedOrgs.length} cancel_workspace_subs=${cancelSubscriptions.length}`
            + ` handed_over_orgs=${isObject(data) ? data.handed_over_orgs : "?"}`
            + ` handed_over_teams=${isObject(data) ? data.handed_over_teams : "?"}`
            + ` deleted_teams=${isObject(data) ? data.deleted_teams : "?"}`,
    );
    return { deletedOrgs, cancelSubscriptions };
}

// The id is logged on failure because nothing else keeps it: the release has
// committed, and for a deleted organization its subscription row is gone.
async function cancelPaddleSubscription(
    subscriptionId: string,
    owner: string,
    effectiveFrom: CancelTiming = "immediately",
): Promise<void> {
    try {
        const res = await fetch(`${PADDLE_API_BASE}/subscriptions/${subscriptionId}/cancel`, {
            method: "POST",
            headers: PADDLE_HEADERS,
            body: JSON.stringify({ effective_from: effectiveFrom }),
        });
        if (!res.ok) {
            console.error(
                `paddle cancel-on-erasure failed sub=${subscriptionId} ${owner} effective_from=${effectiveFrom} status=${res.status} body=${(await res.text()).slice(0, 300)}`,
            );
        }
    } catch (err) {
        console.error(`paddle cancel-on-erasure threw sub=${subscriptionId} ${owner}: ${err}`);
    }
}

// Best effort, like the Paddle cancel: the organization row is already gone, and
// a logo left behind is a public image nobody can reach from the app.
async function removeOrgLogos(admin: SupabaseClient, orgId: string): Promise<void> {
    const bucket = admin.storage.from("org-logos");
    const { data: objects, error } = await bucket.list(orgId, { limit: 1000 });
    if (error) {
        console.warn(`org logo listing failed org=${orgId}: ${error.message}`);
        return;
    }
    const paths = (objects ?? []).map((object) => `${orgId}/${object.name}`);
    if (paths.length === 0) return;
    const { error: removeError } = await bucket.remove(paths);
    if (removeError) console.warn(`org logo removal failed org=${orgId}: ${removeError.message}`);
}
