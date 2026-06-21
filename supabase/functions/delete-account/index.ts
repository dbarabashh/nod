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
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
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
        try {
            const res = await fetch(`${PADDLE_API_BASE}/subscriptions/${sub.paddle_subscription_id}/cancel`, {
                method: "POST",
                headers: PADDLE_HEADERS,
                body: JSON.stringify({ effective_from: "immediately" }),
            });
            if (!res.ok) {
                console.warn(`paddle cancel-on-erasure failed status=${res.status} body=${(await res.text()).slice(0, 300)}`);
            }
        } catch (err) {
            console.warn(`paddle cancel-on-erasure threw: ${err}`);
        }
    }

    // The cascade lives in the FK constraints — deleting the auth user erases
    // every dependent row. `shouldSoftDelete: false` makes it a hard delete in
    // auth.users too (no recoverable banned-user shell left behind).
    const { error } = await admin.auth.admin.deleteUser(user.id, false);
    if (error) {
        console.error(`deleteUser failed user=${user.id}: ${error.message}`);
        return json({ error: "Deletion failed" }, 502);
    }

    console.log(`account erased user=${user.id}`);
    return json({ deleted: true }, 200);
});
