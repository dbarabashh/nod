import { assertEquals } from "jsr:@std/assert@1.0.14";
import { usageContext, usageTokenDetails } from "./usage-context.ts";
import { retryAfterSeconds } from "./rate-limit.ts";

Deno.test("optional metadata never breaks legacy usage or forwards arbitrary text", () => {
    assertEquals(usageContext(undefined), {});
    assertEquals(usageContext({ purpose: "private transcript" }), {});
    assertEquals(usageContext({ purpose: "entities", meeting_id: "bad uuid" }), { purpose: "entities" });
    const context = { purpose: "recap", meeting_id: "00000000-0000-4000-8000-000000000001" };
    assertEquals(usageContext({ ...context, extra: "discard me" }), context);
});

Deno.test("reasoning and cache counters distinguish unknown from zero", () => {
    assertEquals(usageTokenDetails(null), { reasoning_tokens: null, cached_tokens: null });
    assertEquals(usageTokenDetails({ completion_tokens_details: { reasoning_tokens: 0 }, prompt_tokens_details: { cached_tokens: 100 } }), { reasoning_tokens: 0, cached_tokens: 100 });
    for (const invalid of [-1, 0.5, "20", Infinity, 2147483648]) {
        assertEquals(usageTokenDetails({ completion_tokens_details: { reasoning_tokens: invalid } }).reasoning_tokens, null);
    }
});

Deno.test("rate limit delays honor seconds and HTTP dates without early capped retries", () => {
    assertEquals(retryAfterSeconds("120"), 120);
    assertEquals(retryAfterSeconds("90000"), 90000);
    assertEquals(retryAfterSeconds("Wed, 07 Oct 2026 12:02:00 GMT", Date.parse("2026-10-07T12:00:00Z")), 120);
    assertEquals(retryAfterSeconds(null), 60);
    assertEquals(retryAfterSeconds("junk"), 60);
});
