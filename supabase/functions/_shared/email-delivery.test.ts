import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { providerFailure, templateVariables, unsubscribeHeaders } from "./email-delivery.ts";
import { syncContactTopic } from "./resend-contact.ts";
import { verifySvix } from "./svix.ts";

Deno.test("only rate limits and provider faults are retried", async () => {
    assertEquals((await providerFailure("send", new Response("busy", { status: 429 }))).retryable, true);
    assertEquals((await providerFailure("send", new Response("down", { status: 503 }))).retryable, true);
    assertEquals((await providerFailure("send", new Response("bad", { status: 422 }))).retryable, false);
});

Deno.test("template variables exclude internal identifiers", () => {
    assertEquals(
        templateVariables({
            FIRST_NAME: "Ada",
            calendly_url: "https://example.com",
            reward_credit_id: "internal",
            nested: { hidden: true },
        }),
        { FIRST_NAME: "Ada", calendly_url: "https://example.com" },
    );
});

Deno.test("an unsubscribe header is emitted only for a real preference link", () => {
    assertEquals(
        unsubscribeHeaders({ PREFERENCE_URL: "https://hellonod.app/email-preferences#abc" }),
        { "List-Unsubscribe": "<https://hellonod.app/email-preferences#abc>" },
    );
    assertEquals(unsubscribeHeaders({ PREFERENCE_URL: "javascript:alert(1)" }), {});
    assertEquals(unsubscribeHeaders({}), {});
});

Deno.test("an unsubscribed contact the provider never had stays absent", async () => {
    const calls: Array<{ path: string; method: string }> = [];
    const result = await syncContactTopic(
        (path, init) => {
            calls.push({ path, method: init.method ?? "GET" });
            return Promise.resolve(new Response("missing", { status: 404 }));
        },
        "no-consent@example.invalid",
        "topic-id",
        "opt_out",
    );

    assertEquals(result, { error: null, retryable: false });
    assertEquals(calls, [{ path: "/contacts/no-consent%40example.invalid/topics", method: "PATCH" }]);
});

Deno.test("a topic patch sends the bare array the provider validates", async () => {
    const bodies: string[] = [];
    const record = (_path: string, init: RequestInit) => {
        bodies.push(String(init.body ?? ""));
        return Promise.resolve(new Response("{}", { status: 200 }));
    };

    await syncContactTopic(record, "out@example.invalid", "topic-id", "opt_out");
    assertEquals(JSON.parse(bodies[0]), [{ id: "topic-id", subscription: "opt_out" }]);

    bodies.length = 0;
    await syncContactTopic(
        (path, init) =>
            path === "/contacts" ? Promise.resolve(new Response("exists", { status: 409 })) : record(path, init),
        "in@example.invalid",
        "topic-id",
        "opt_in",
    );
    assertEquals(JSON.parse(bodies[0]), [{ id: "topic-id", subscription: "opt_in" }]);
});

Deno.test("a consented contact is created with an explicit topic state", async () => {
    const bodies: string[] = [];
    const result = await syncContactTopic(
        (_path, init) => {
            bodies.push(String(init.body ?? ""));
            return Promise.resolve(new Response("{}", { status: 201 }));
        },
        "consent@example.invalid",
        "topic-id",
        "opt_in",
    );

    assertEquals(result, { error: null, retryable: false });
    assertEquals(JSON.parse(bodies[0]), {
        email: "consent@example.invalid",
        topics: [{ id: "topic-id", subscription: "opt_in" }],
    });
});

Deno.test("svix accepts a valid signature and rejects a stale or wrong one", async () => {
    const payload = '{"type":"email.delivered"}';
    const eventId = "evt_test";
    const timestamp = "2000000000";
    const secretBytes = new TextEncoder().encode("test-secret");
    const secret = `whsec_${btoa(String.fromCharCode(...secretBytes))}`;
    const secretBuffer = new ArrayBuffer(secretBytes.byteLength);
    new Uint8Array(secretBuffer).set(secretBytes);
    const key = await crypto.subtle.importKey(
        "raw",
        secretBuffer,
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const digest = new Uint8Array(
        await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${eventId}.${timestamp}.${payload}`)),
    );
    const signature = `v1,${btoa(String.fromCharCode(...digest))}`;

    assertEquals(await verifySvix(payload, eventId, timestamp, signature, secret, 2_000_000_000_000), true);
    assertEquals(await verifySvix(payload, eventId, timestamp, signature, secret, 2_000_001_000_000), false);
    assertEquals(await verifySvix(payload, eventId, timestamp, "v1,bad", secret, 2_000_000_000_000), false);
});
