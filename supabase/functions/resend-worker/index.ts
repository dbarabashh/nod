// resend-worker — the only thing that talks to Resend on our behalf.
//
// Supabase decides everything (consent, cadence, eligibility, idempotency); this
// function drains three queues and reports what the provider said:
//   1. contact deletions — an erased account must disappear from the provider
//   2. contact topic sync — Resend mirrors our consent, it never defines it
//   3. the email outbox — one send per claimed row, with an idempotency key
//
// Every send passes `email_outbox_send_guard` first, so consent, suppression,
// the program gate and the underlying entity are re-checked at the last possible
// moment rather than at queueing time.
//
// Called by pg_cron via `invoke_internal_edge_job`, authenticated with the
// shared `INTERNAL_JOB_SECRET` bearer.

import {
    isObject,
    providerFailure,
    stringValue,
    templateVariables,
    unsubscribeHeaders,
} from "../_shared/email-delivery.ts";
import { json } from "../_shared/http.ts";
import { syncContactTopic } from "../_shared/resend-contact.ts";
import { adminClient } from "../_shared/supabase.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const RESEND_API_BASE = Deno.env.get("RESEND_API_BASE") ?? "https://api.resend.com";
const TOPIC_IDS: Record<string, string | undefined> = {
    product_updates: Deno.env.get("RESEND_PRODUCT_UPDATES_TOPIC_ID"),
    lifecycle_guidance: Deno.env.get("RESEND_LIFECYCLE_GUIDANCE_TOPIC_ID"),
    founder_research: Deno.env.get("RESEND_FOUNDER_RESEARCH_TOPIC_ID"),
};
const FROM = "Dima from Nod <dmytro@hellonod.app>";
const REPLY_TO = "dmytro@hellonod.app";

// The template aliases never change between deploys, so checking each one on
// every send would double our provider calls for no information.
const TEMPLATE_CACHE_TTL_MS = 10 * 60 * 1000;
const publishedTemplates = new Map<string, number>();

Deno.serve(async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!configured()) {
        console.error("resend-worker missing env: INTERNAL_JOB_SECRET / RESEND_API_KEY / topic ids");
        return json({ error: "Server misconfigured" }, 500);
    }
    if (request.headers.get("Authorization") !== `Bearer ${INTERNAL_JOB_SECRET}`) {
        return json({ error: "Unauthenticated" }, 401);
    }

    try {
        const admin = adminClient();
        const deletions = await processContactDeletions(admin);
        const contacts = await processContactSync(admin);
        const emails = await processEmailOutbox(admin);
        return json({ contact_deletions: deletions, contacts, emails }, 200);
    } catch (error) {
        console.error(`resend-worker failed: ${error}`);
        return json({ error: "Worker failed" }, 500);
    }
});

function configured(): boolean {
    return Boolean(
        INTERNAL_JOB_SECRET && RESEND_API_KEY &&
            TOPIC_IDS.product_updates && TOPIC_IDS.lifecycle_guidance && TOPIC_IDS.founder_research,
    );
}

async function processContactDeletions(
    admin: ReturnType<typeof adminClient>,
): Promise<Record<string, number>> {
    const { data: rows, error } = await admin.rpc("claim_resend_contact_deletions", { p_limit: 20 });
    if (error) throw new Error(`claim_resend_contact_deletions: ${error.message}`);

    let deleted = 0;
    let failed = 0;
    for (const row of rows ?? []) {
        const id = stringValue(row.id);
        const email = stringValue(row.email);
        if (!id || !email) continue;
        try {
            const response = await resendFetch(`/contacts/${encodeURIComponent(email)}`, { method: "DELETE" });
            // 404 is success: there is nothing left to erase.
            if (response.ok || response.status === 404) {
                await admin.rpc("complete_resend_contact_deletion", {
                    p_id: id,
                    p_deleted: true,
                    p_error: null,
                    p_retryable: false,
                });
                deleted += 1;
            } else {
                const failure = await providerFailure("delete contact", response);
                await admin.rpc("complete_resend_contact_deletion", {
                    p_id: id,
                    p_deleted: false,
                    p_error: failure.error,
                    p_retryable: failure.retryable,
                });
                failed += 1;
            }
        } catch (error) {
            await admin.rpc("complete_resend_contact_deletion", {
                p_id: id,
                p_deleted: false,
                p_error: `contact deletion network failure: ${error}`,
                p_retryable: true,
            });
            failed += 1;
        }
    }
    return { claimed: (rows ?? []).length, deleted, failed };
}

async function processContactSync(
    admin: ReturnType<typeof adminClient>,
): Promise<Record<string, number>> {
    const { data: rows, error } = await admin.rpc("claim_resend_contact_sync", { p_limit: 20 });
    if (error) throw new Error(`claim_resend_contact_sync: ${error.message}`);

    let synced = 0;
    let failed = 0;
    for (const row of rows ?? []) {
        const id = stringValue(row.id);
        const email = stringValue(row.email);
        const topic = stringValue(row.topic);
        const desired = stringValue(row.desired_status);
        const topicId = TOPIC_IDS[topic];
        if (!id || !email || !topicId) continue;

        // Someone who changed their mind while this row waited in the queue wins.
        const { data: current, error: guardError } = await admin.rpc("resend_contact_sync_guard", {
            p_id: id,
            p_desired_status: desired,
        });
        if (guardError || current !== true) {
            await admin.rpc("complete_resend_contact_sync", {
                p_id: id,
                p_error: "stale_contact_preference",
                p_retryable: false,
            });
            failed += 1;
            continue;
        }

        try {
            const result = await syncContactTopic(
                resendFetch,
                email,
                topicId,
                desired === "subscribed" ? "opt_in" : "opt_out",
            );
            await admin.rpc("complete_resend_contact_sync", {
                p_id: id,
                p_error: result.error,
                p_retryable: result.retryable,
            });
            if (result.error) failed += 1;
            else synced += 1;
        } catch (error) {
            await admin.rpc("complete_resend_contact_sync", {
                p_id: id,
                p_error: `contact sync network failure: ${error}`,
                p_retryable: true,
            });
            failed += 1;
        }
    }
    return { claimed: (rows ?? []).length, synced, failed };
}

async function processEmailOutbox(
    admin: ReturnType<typeof adminClient>,
): Promise<Record<string, number>> {
    const { data: rows, error } = await admin.rpc("claim_email_outbox", { p_limit: 20 });
    if (error) throw new Error(`claim_email_outbox: ${error.message}`);

    let accepted = 0;
    let deferred = 0;
    let rejected = 0;
    let unknown = 0;
    let canceled = 0;

    for (const row of rows ?? []) {
        const id = stringValue(row.id);
        if (!id) continue;

        const { data: maySend, error: guardError } = await admin.rpc("email_outbox_send_guard", { p_id: id });
        if (guardError || maySend !== true) {
            await admin.rpc("complete_email_outbox", {
                p_id: id,
                p_outcome: "canceled",
                p_provider_email_id: null,
                p_error: guardError?.message ?? "send_guard_rejected",
                p_retryable: false,
            });
            canceled += 1;
            continue;
        }

        // Read the payload AFTER the guard: it may have re-pointed the row at the
        // template the recipient is actually consented to right now.
        const { data: delivery, error: payloadError } = await admin.rpc("email_outbox_delivery_payload", { p_id: id });
        const alias = isObject(delivery) ? stringValue(delivery.template_alias) : "";
        const email = isObject(delivery) ? stringValue(delivery.email) : "";
        const payload = isObject(delivery) ? delivery.payload : null;
        if (payloadError || !alias || !email) {
            await admin.rpc("defer_email_outbox", {
                p_id: id,
                p_error: payloadError?.message ?? "delivery_payload_unavailable",
            });
            deferred += 1;
            continue;
        }

        try {
            if (!(await templateIsPublished(alias))) {
                await admin.rpc("defer_email_outbox", { p_id: id, p_error: `template_not_published:${alias}` });
                deferred += 1;
                continue;
            }
        } catch (error) {
            await admin.rpc("defer_email_outbox", { p_id: id, p_error: `template_status_unavailable:${error}` });
            deferred += 1;
            continue;
        }

        // Marks the row as "a provider call may exist from here on". Anything
        // after this point is resolved, never retried blindly.
        const { data: leased, error: leaseError } = await admin.rpc("begin_email_provider_request", {
            p_id: id,
            p_expected_template_alias: alias,
        });
        if (leaseError || leased !== true) {
            await admin.rpc("defer_email_outbox", {
                p_id: id,
                p_error: leaseError?.message ?? "provider_request_lease_unavailable",
            });
            deferred += 1;
            continue;
        }

        let response: Response;
        try {
            response = await resendFetch("/emails", {
                method: "POST",
                headers: {
                    "Idempotency-Key": `nod-email-${id}`,
                    ...unsubscribeHeaders(payload),
                },
                body: JSON.stringify({
                    from: FROM,
                    reply_to: REPLY_TO,
                    to: email,
                    template: { id: alias, variables: templateVariables(payload) },
                }),
            });
        } catch (error) {
            // The request may have reached Resend. The idempotency key protects a
            // future retry, but we still record the ambiguity instead of guessing.
            await admin.rpc("complete_email_outbox", {
                p_id: id,
                p_outcome: "delivery_unknown",
                p_provider_email_id: null,
                p_error: `provider_request_outcome_unknown:${error}`,
                p_retryable: false,
            });
            unknown += 1;
            continue;
        }

        if (response.ok) {
            let providerId = "";
            try {
                providerId = stringValue((await response.json())?.id);
            } catch {
                providerId = "";
            }
            if (!providerId) {
                await admin.rpc("complete_email_outbox", {
                    p_id: id,
                    p_outcome: "delivery_unknown",
                    p_provider_email_id: null,
                    p_error: "provider_accepted_without_parseable_id",
                    p_retryable: false,
                });
                unknown += 1;
                continue;
            }
            await admin.rpc("complete_email_outbox", {
                p_id: id,
                p_outcome: "accepted",
                p_provider_email_id: providerId,
                p_error: null,
                p_retryable: false,
            });
            accepted += 1;
            continue;
        }

        const failure = await providerFailure("send email", response);
        await admin.rpc("complete_email_outbox", {
            p_id: id,
            p_outcome: "rejected",
            p_provider_email_id: null,
            p_error: failure.error,
            p_retryable: failure.retryable,
        });
        rejected += 1;
    }

    return { claimed: (rows ?? []).length, accepted, deferred, rejected, unknown, canceled };
}

// An unpublished template renders as an empty email, so a send is deferred
// rather than attempted. Positive answers are cached; a miss is always re-asked.
async function templateIsPublished(alias: string): Promise<boolean> {
    const cachedAt = publishedTemplates.get(alias);
    if (cachedAt && Date.now() - cachedAt < TEMPLATE_CACHE_TTL_MS) return true;

    const response = await resendFetch(`/templates/${encodeURIComponent(alias)}`, { method: "GET" });
    if (!response.ok) return false;
    const published = (await response.json())?.status === "published";
    if (published) publishedTemplates.set(alias, Date.now());
    return published;
}

function resendFetch(path: string, init: RequestInit): Promise<Response> {
    return fetch(`${RESEND_API_BASE}${path}`, {
        ...init,
        signal: init.signal ?? AbortSignal.timeout(20_000),
        headers: {
            "Authorization": `Bearer ${RESEND_API_KEY}`,
            "Content-Type": "application/json",
            ...init.headers,
        },
    });
}
