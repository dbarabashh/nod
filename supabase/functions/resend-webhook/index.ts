// resend-webhook — provider delivery truth, made idempotent.
//
// Resend signs deliveries with Svix over the raw body, so verification happens
// before anything is parsed. Each event is recorded once by its provider event
// id; a replay is acknowledged and ignored. Bounces and complaints suppress the
// address immediately and cancel anything still queued for it — that is the
// difference between one bad address and a burned sending domain.
//
// `contact.updated` mirrors a provider-side OPT-OUT into Supabase. It never
// mirrors an opt-in: consent is only ever created in our own surfaces.

import { isObject, stringValue } from "../_shared/email-delivery.ts";
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { verifySvix } from "../_shared/svix.ts";

const RESEND_WEBHOOK_SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET");
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const RESEND_API_BASE = Deno.env.get("RESEND_API_BASE") ?? "https://api.resend.com";
const TOPICS: Record<string, string | undefined> = {
    product_updates: Deno.env.get("RESEND_PRODUCT_UPDATES_TOPIC_ID"),
    lifecycle_guidance: Deno.env.get("RESEND_LIFECYCLE_GUIDANCE_TOPIC_ID"),
    founder_research: Deno.env.get("RESEND_FOUNDER_RESEARCH_TOPIC_ID"),
};

Deno.serve(async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!RESEND_WEBHOOK_SECRET || !RESEND_API_KEY || Object.values(TOPICS).some((value) => !value)) {
        console.error("resend-webhook missing env: RESEND_WEBHOOK_SECRET / RESEND_API_KEY / topic ids");
        return json({ error: "Server misconfigured" }, 500);
    }

    const rawBody = await request.text();
    const eventId = request.headers.get("svix-id") ?? "";
    const timestamp = request.headers.get("svix-timestamp") ?? "";
    const signature = request.headers.get("svix-signature") ?? "";
    if (!(await verifySvix(rawBody, eventId, timestamp, signature, RESEND_WEBHOOK_SECRET))) {
        console.warn("resend webhook signature verification failed");
        return json({ error: "Invalid signature" }, 401);
    }

    let event: Record<string, unknown>;
    try {
        const parsed = JSON.parse(rawBody);
        if (!isObject(parsed)) throw new Error("invalid event");
        event = parsed;
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }

    const data = isObject(event.data) ? event.data : {};
    const type = stringValue(event.type);
    const email = eventEmail(data);
    const occurredAt = stringValue(event.created_at) || stringValue(data.created_at) || null;
    const providerEmailId = stringValue(data.email_id) || stringValue(data.id) || null;

    const admin = adminClient();
    const { data: inserted, error } = await admin.rpc("record_email_webhook", {
        p_provider_event_id: eventId,
        p_event_type: type,
        // Only email events carry a provider email id; a contact event's `id` is
        // the contact, and confusing the two would attribute the wrong delivery.
        p_provider_email_id: type.startsWith("email.") ? providerEmailId : null,
        p_email: email || null,
        p_payload: event,
        p_occurred_at: occurredAt,
    });
    if (error) {
        console.error(`record_email_webhook failed event=${eventId}: ${error.message}`);
        return json({ error: "Handler error" }, 500);
    }
    if (inserted === false) {
        return json({ ok: true, duplicate: true }, 200);
    }

    if (type === "contact.updated") {
        try {
            await reconcileContactTopics(admin, stringValue(data.id), email);
            const { error: completionError } = await admin.rpc("complete_email_webhook_event", {
                p_provider_event_id: eventId,
            });
            if (completionError) throw new Error(`complete_email_webhook_event: ${completionError.message}`);
        } catch (topicError) {
            // 500 so Resend retries: an unmirrored opt-out is the one failure we
            // must not swallow.
            console.error(`contact topic reconciliation failed event=${eventId}: ${topicError}`);
            return json({ error: "Topic reconciliation failed" }, 500);
        }
    }

    return json({ ok: true, duplicate: false }, 200);
});

async function reconcileContactTopics(
    admin: ReturnType<typeof adminClient>,
    contactId: string,
    eventEmailValue: string,
): Promise<void> {
    const identifier = contactId || eventEmailValue;
    if (!identifier) throw new Error("contact event missing identity");

    const topicsResponse = await resendGet(`/contacts/${encodeURIComponent(identifier)}/topics`);
    if (!topicsResponse.ok) throw new Error(`contact topics status=${topicsResponse.status}`);
    const topicsBody = await topicsResponse.json();
    const providerTopics = Array.isArray(topicsBody?.data) ? topicsBody.data : [];

    let email = eventEmailValue;
    if (!email && contactId) {
        const contactResponse = await resendGet(`/contacts/${encodeURIComponent(contactId)}`);
        if (!contactResponse.ok) throw new Error(`contact lookup status=${contactResponse.status}`);
        email = stringValue((await contactResponse.json())?.email);
    }
    if (!email) throw new Error("contact event missing email");

    for (const [topic, topicId] of Object.entries(TOPICS)) {
        const providerTopic = providerTopics.find((candidate: unknown) =>
            isObject(candidate) && candidate.id === topicId
        );
        if (!isObject(providerTopic)) continue;
        if (stringValue(providerTopic.subscription) !== "opt_out") continue;

        const { error } = await admin.rpc("apply_resend_topic_status", {
            p_email: email,
            p_topic: topic,
            p_status: "unsubscribed",
            p_provider_event_id: null,
        });
        if (error) throw new Error(`apply_resend_topic_status: ${error.message}`);
    }
}

function eventEmail(data: Record<string, unknown>): string {
    if (Array.isArray(data.to)) {
        const address = data.to.find((candidate) => typeof candidate === "string");
        if (typeof address === "string") return address;
    }
    return stringValue(data.email);
}

function resendGet(path: string): Promise<Response> {
    return fetch(`${RESEND_API_BASE}${path}`, {
        method: "GET",
        signal: AbortSignal.timeout(20_000),
        headers: { Authorization: `Bearer ${RESEND_API_KEY}` },
    });
}
