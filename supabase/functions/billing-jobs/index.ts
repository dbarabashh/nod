// Scheduled billing worker: expires reward credits that were never claimed and
// applies the ones whose seven-day hold has passed.
//
// Called by pg_cron through `invoke_internal_edge_job`, which signs the call
// with `INTERNAL_JOB_SECRET` — there is no user session here, so the bearer
// secret is the whole authentication.
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import { adminClient } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { payoutDueRewards } from "../_shared/reward-payout.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!INTERNAL_JOB_SECRET) {
        console.error("missing env: INTERNAL_JOB_SECRET");
        return json({ error: "Server misconfigured" }, 500);
    }
    if (req.headers.get("Authorization") !== `Bearer ${INTERNAL_JOB_SECRET}`) {
        return json({ error: "Unauthenticated" }, 401);
    }

    const admin = adminClient();

    const { data: expired, error: expiryError } = await admin.rpc("expire_reward_credits");
    if (expiryError) {
        console.error(`expire_reward_credits failed: ${expiryError.message}`);
        return json({ error: "Reward expiry failed" }, 502);
    }

    const { data: candidates, error: candidateError } = await admin.rpc("reward_payout_candidates", { p_limit: 50 });
    if (candidateError) {
        console.error(`reward_payout_candidates failed: ${candidateError.message}`);
        return json({ error: "Candidate lookup failed" }, 502);
    }

    let applied = 0;
    let failed = 0;
    for (const row of candidates ?? []) {
        const userId = typeof row?.beneficiary_user_id === "string" ? row.beneficiary_user_id : "";
        if (!userId) continue;
        // One provider write per beneficiary per run. A failure is left for the
        // next run rather than retried in a tight loop.
        if (await payoutDueRewards(admin, userId)) applied += 1;
        else failed += 1;
    }

    console.log(`billing jobs expired=${expired ?? 0} candidates=${(candidates ?? []).length} applied=${applied} failed=${failed}`);
    return json({
        expired: expired ?? 0,
        candidates: (candidates ?? []).length,
        applied,
        failed,
    }, 200);
});
