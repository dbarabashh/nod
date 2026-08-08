// export-account — GDPR Right of Access & Data Portability (Art. 15 / 20).
// Returns ALL of the signed-in user's personal data as one machine-readable
// JSON document the user can download from Settings (or we can hand over on a
// subject-access request).
//
// Request shape (POST /functions/v1/export-account):
//   Authorization: Bearer <supabase-access-token>
// Response:        application/json — the full export document (see `Export`).
//
// We read with the service role scoped by `user_id` (equivalent to each table's
// per-user RLS, but able to page large tables without RLS round-trips). Every
// table that holds the user's personal data is included. The session-embedding
// VECTORS are deliberately omitted — they're a derived numerical representation
// with no meaning to the data subject and would bloat the file by megabytes;
// the human-readable `content` of each chunk IS included, so nothing legible is
// withheld.
//
// Deployed per-branch via git: develop (sandbox) and main (live) each from theirs.

import { adminClient, authenticate } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const PAGE = 1000;

// Read every row of `table` for this user, paging past Postgres' 1000-row cap so
// a heavy account (thousands of transcript chunks) exports in full.
async function fetchAll(
    admin: SupabaseClient,
    table: string,
    columns: string,
    userColumn = "user_id",
    userId = "",
): Promise<unknown[]> {
    const rows: unknown[] = [];
    for (let from = 0; ; from += PAGE) {
        const { data, error } = await admin
            .from(table)
            .select(columns)
            .eq(userColumn, userId)
            .range(from, from + PAGE - 1);
        if (error) {
            console.error(`export read ${table} failed: ${error.message}`);
            throw new Error(`read ${table}`);
        }
        rows.push(...(data ?? []));
        if (!data || data.length < PAGE) break;
    }
    return rows;
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
        console.error("missing env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;
    const uid = user.id;

    const admin = adminClient();

    try {
        const [
            profile, meetings, transcripts, chatMessages, entities, meetingEntities,
            labels, meetingLabels, embeddings, shares, devices, usageEvents,
            subscription, usageCredits, consent, onboardingEvents, productEvents,
        ] = await Promise.all([
            fetchAll(admin, "profiles", "*", "user_id", uid),
            fetchAll(admin, "meetings", "*", "user_id", uid),
            fetchAll(admin, "meeting_transcripts", "*", "user_id", uid),
            fetchAll(admin, "chat_messages", "*", "user_id", uid),
            fetchAll(admin, "entities", "*", "user_id", uid),
            fetchAll(admin, "meeting_entities", "*", "user_id", uid),
            fetchAll(admin, "labels", "*", "user_id", uid),
            fetchAll(admin, "meeting_labels", "*", "user_id", uid),
            fetchAll(admin, "session_embeddings", "id, meeting_id, chunk_idx, content, created_at", "user_id", uid),
            fetchAll(admin, "meeting_shares", "*", "created_by", uid),
            fetchAll(admin, "user_devices", "*", "user_id", uid),
            fetchAll(admin, "usage_events", "*", "user_id", uid),
            fetchAll(admin, "subscriptions", "*", "user_id", uid),
            fetchAll(admin, "usage_credits", "*", "user_id", uid),
            fetchAll(admin, "consent_acknowledgements", "*", "user_id", uid),
            fetchAll(admin, "onboarding_events", "*", "user_id", uid),
            fetchAll(admin, "product_events", "*", "user_id", uid),
        ]);

        const exportDoc = {
            export_format_version: 2,
            note:
                "Your complete personal data held by Nod. Audio is never stored, so it is "
                + "not included. Session-embedding vectors are omitted (derived numeric data); "
                + "each chunk's readable text is included under session_embeddings.",
            account: {
                id: user.id,
                email: user.email ?? null,
                provider: user.app_metadata?.provider ?? null,
                created_at: user.created_at ?? null,
                last_sign_in_at: user.last_sign_in_at ?? null,
                identity: user.user_metadata ?? {},
            },
            profile: profile[0] ?? null,
            meetings,
            meeting_transcripts: transcripts,
            chat_messages: chatMessages,
            entities,
            meeting_entities: meetingEntities,
            labels,
            meeting_labels: meetingLabels,
            session_embeddings: embeddings,
            meeting_shares: shares,
            user_devices: devices,
            usage_events: usageEvents,
            subscription: subscription[0] ?? null,
            usage_credits: usageCredits,
            consent_acknowledgements: consent,
            onboarding_events: onboardingEvents,
            product_events: productEvents,
        };

        console.log(`account exported user=${uid} meetings=${meetings.length} transcripts=${transcripts.length}`);
        return new Response(JSON.stringify(exportDoc, null, 2), {
            status: 200,
            headers: {
                "Content-Type": "application/json",
                "Content-Disposition": 'attachment; filename="nod-data-export.json"',
            },
        });
    } catch {
        return json({ error: "Export failed" }, 502);
    }
});
