import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.14";
import { UpstreamRateLimit } from "./rate-limit.ts";

Deno.env.set("SUPABASE_URL", "http://localhost:54321");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-only-key");
Deno.env.set("OPENROUTER_API_KEY", "test-only-key");
const { forwardChat } = await import("./chat.ts");
const { completeOnce } = await import("./complete.ts");
const { handleDistill } = await import("./knowledge.ts");
const user = "00000000-0000-4000-8000-000000000001";
const meeting = "00000000-0000-4000-8000-000000000002";
const usage = {
    prompt_tokens: 100, completion_tokens: 40, cost: 0.001,
    completion_tokens_details: { reasoning_tokens: 30 },
    prompt_tokens_details: { cached_tokens: 50 },
};

for (const streamed of [false, true]) {
    for (const context of [undefined, { purpose: "recap", meeting_id: meeting }]) {
        Deno.test(`${streamed ? "streamed" : "buffered"} chat meters legacy and new clients: metadata=${!!context}`, async () => {
            const previous = globalThis.fetch;
            const records: Record<string, unknown>[] = [];
            const pending: Promise<unknown>[] = [];
            const runtime = globalThis as typeof globalThis & { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } };
            const oldRuntime = runtime.EdgeRuntime;
            runtime.EdgeRuntime = { waitUntil: (promise) => { pending.push(promise); } };
            globalThis.fetch = async (input, init) => {
                const url = String(input);
                const body = JSON.parse(String(init?.body));
                if (url.includes("/rest/v1/usage_events")) {
                    records.push(body);
                    return new Response(null, { status: 201 });
                }
                assert(url === "https://openrouter.ai/api/v1/chat/completions");
                assertEquals(body.reasoning, { enabled: false });
                assertEquals(body.model, "anthropic/claude-sonnet-5");
                for (const internal of ["task", "context", "purpose", "meeting_id"]) assertEquals(body[internal], undefined);
                const frame = { id: "generation-test", model: body.model, choices: [{ delta: { content: "ok" }, finish_reason: "stop" }], usage };
                return new Response(`data: ${JSON.stringify(frame)}\n\ndata: [DONE]\n\n`, { headers: { "Content-Type": "text/event-stream" } });
            };
            try {
                const response = await forwardChat({ model: "anthropic/claude-sonnet-4.6", task: "summary", messages: [], stream: streamed, reasoning: { effort: "high" } }, user, context);
                assertEquals(response.status, 200);
                await response.text();
                await Promise.all(pending);
                assertEquals(records.length, 1);
                assertEquals(records[0].cost_usd, 0.001);
                assertEquals(records[0].completion_tokens, 40);
                assertEquals(records[0].reasoning_tokens, 30);
                assertEquals(records[0].cached_tokens, 50);
                assertEquals(records[0].model, "anthropic/claude-sonnet-4.6");
                assertEquals(records[0].resolved_model, "anthropic/claude-sonnet-5");
                assertEquals(records[0].purpose, context?.purpose);
                assertEquals(records[0].meeting_id, context?.meeting_id);
            } finally {
                globalThis.fetch = previous;
                runtime.EdgeRuntime = oldRuntime;
            }
        });
    }
}

Deno.test("distillation propagates provider cooldown after exactly one billed attempt", async () => {
    const previous = globalThis.fetch;
    let calls = 0;
    let writes = 0;
    globalThis.fetch = async (input, init) => {
        if (String(input).includes("/rest/v1/usage_events")) {
            writes++;
            const row = JSON.parse(String(init?.body));
            assertEquals(row.status, 429);
            assertEquals(row.meeting_id, meeting);
            return new Response(null, { status: 201 });
        }
        assertEquals(String(input), "https://openrouter.ai/api/v1/chat/completions");
        calls++;
        return Response.json({ error: "rate limited" }, { status: 429, headers: { "Retry-After": "120" } });
    };
    try {
        const error = await assertRejects(() => completeOnce({ model: "mistralai/mistral-small-2603", system: "test", user: "test", userId: user, task: "distill", meetingId: meeting, deferRateLimits: true }), UpstreamRateLimit);
        assertEquals(error.retryAfterSeconds, 120);
        assertEquals(calls, 1);
        assertEquals(writes, 1);
    } finally { globalThis.fetch = previous; }
});

Deno.test("completed backfill is skipped with ownership check; legacy regeneration still runs", async () => {
    const previous = globalThis.fetch;
    let transcriptReads = 0;
    globalThis.fetch = async (input, init) => {
        const url = new URL(String(input));
        assertEquals(url.origin, "http://localhost:54321");
        if (url.pathname.endsWith("/meetings")) {
            if (init?.method === "PATCH") return new Response(null, { status: 204 });
            assertEquals(url.searchParams.get("user_id"), `eq.${user}`);
            return Response.json({ id: meeting, started_at: "2026-10-05T23:00:00Z", ended_at: "2026-10-06T00:00:00Z", distilled_at: "2026-10-06T01:00:00Z" });
        }
        if (url.pathname.endsWith("/meeting_transcripts")) { transcriptReads++; return Response.json([]); }
        if (url.pathname.endsWith("/meeting_entities")) return Response.json([]);
        throw new Error(`unexpected request ${url.pathname}`);
    };
    try {
        assertEquals((await handleDistill({ meeting_id: meeting, skip_completed: true }, user)).status, 200);
        assertEquals(transcriptReads, 0);
        assertEquals((await handleDistill({ meeting_id: meeting }, user)).status, 200);
        assertEquals(transcriptReads, 1);
    } finally { globalThis.fetch = previous; }
});

Deno.test("active meeting timestamp sentinel cannot be distilled or marked complete", async () => {
    const previous = globalThis.fetch;
    let reads = 0;
    globalThis.fetch = async (input, init) => {
        const url = new URL(String(input));
        assert(url.pathname.endsWith("/meetings"));
        assertEquals(init?.method ?? "GET", "GET");
        reads++;
        return Response.json({ started_at: "2026-10-07T12:00:00Z", ended_at: "2026-10-07T12:00:00Z", distilled_at: null });
    };
    try {
        assertEquals((await handleDistill({ meeting_id: meeting, skip_completed: true }, user)).status, 422);
        assertEquals(reads, 1);
    } finally { globalThis.fetch = previous; }
});
