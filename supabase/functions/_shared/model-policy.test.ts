import { assertEquals } from "jsr:@std/assert@1.0.14";
import { applyModelPolicy, reasoningDisabled, sttRoutingMode, supportsExplicitPromptCache } from "./model-policy.ts";

function withEnv(vars: Record<string, string>, body: () => void) {
    for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
    try {
        body();
    } finally {
        for (const k of Object.keys(vars)) Deno.env.delete(k);
    }
}

const payload = { model: "anthropic/claude-sonnet-4.6", models: ["anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"] };

Deno.test("no policy set leaves the client's choice alone", () => {
    const r = applyModelPolicy(payload, "summary", "anthropic/claude-sonnet-4.6");
    assertEquals(r.routed, "anthropic/claude-sonnet-4.6");
    assertEquals(r.payload, payload);
});

Deno.test("policy re-routes a stock client default", () => {
    withEnv({ SUMMARY_MODEL: "anthropic/claude-sonnet-5" }, () => {
        const r = applyModelPolicy(payload, "summary", "anthropic/claude-sonnet-4.6");
        assertEquals(r.routed, "anthropic/claude-sonnet-5");
        assertEquals(r.payload.model, "anthropic/claude-sonnet-5");
        assertEquals(r.payload.models, [
            "anthropic/claude-sonnet-5",
            "anthropic/claude-sonnet-4.6",
            "anthropic/claude-haiku-4.5",
        ]);
    });
});

Deno.test("a full client chain stays within OpenRouter's 3-model limit", () => {
    // The client sends primary + model + fallback. Prepending the policy model
    // made four, and OpenRouter 400s on that — it broke chat and assist in the
    // sandbox until the chain was capped.
    const full = {
        model: "anthropic/claude-sonnet-5",
        models: ["anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"],
    };
    withEnv({ CHAT_MODEL: "openai/gpt-5.6-luna" }, () => {
        const r = applyModelPolicy(full, "chat", "anthropic/claude-sonnet-5");
        assertEquals(r.routed, "openai/gpt-5.6-luna");
        assertEquals((r.payload.models as string[]).length, 3);
        assertEquals((r.payload.models as string[])[0], "openai/gpt-5.6-luna");
    });
});

Deno.test("an explicit user override is never re-routed", () => {
    withEnv({ SUMMARY_MODEL: "anthropic/claude-sonnet-5" }, () => {
        const r = applyModelPolicy({ model: "google/gemini-2.5-pro" }, "summary", "google/gemini-2.5-pro");
        assertEquals(r.routed, "google/gemini-2.5-pro");
    });
});

Deno.test("a task keeps its own knob — summary does not move title", () => {
    withEnv({ SUMMARY_MODEL: "anthropic/claude-sonnet-5" }, () => {
        const r = applyModelPolicy(payload, "title", "anthropic/claude-sonnet-4.6");
        assertEquals(r.routed, "anthropic/claude-sonnet-4.6");
    });
});

Deno.test("an unknown task is never re-routed", () => {
    withEnv({ SUMMARY_MODEL: "anthropic/claude-sonnet-5" }, () => {
        const r = applyModelPolicy(payload, "unknown", "anthropic/claude-sonnet-4.6");
        assertEquals(r.routed, "anthropic/claude-sonnet-4.6");
    });
});

Deno.test("stt routing falls back to groq_primary on an unknown value", () => {
    assertEquals(sttRoutingMode(), "groq_primary");
    withEnv({ STT_ROUTING_MODE: "nonsense" }, () => assertEquals(sttRoutingMode(), "groq_primary"));
    withEnv({ STT_ROUTING_MODE: "openrouter_only" }, () => assertEquals(sttRoutingMode(), "openrouter_only"));
});

Deno.test("only anthropic and google take an explicit cache marker", () => {
    assertEquals(supportsExplicitPromptCache("anthropic/claude-sonnet-5"), true);
    assertEquals(supportsExplicitPromptCache("google/gemini-3.1-flash-lite"), true);
    assertEquals(supportsExplicitPromptCache("openai/gpt-5.6-luna"), false);
    assertEquals(supportsExplicitPromptCache(undefined), false);
});

Deno.test("reasoning stays on unless the task is listed", () => {
    if (reasoningDisabled("chat")) throw new Error("unset policy must leave reasoning alone");
    withEnv({ DISABLE_REASONING_TASKS: "chat" }, () => {
        assertEquals(reasoningDisabled("chat"), true);
        assertEquals(reasoningDisabled("summary"), false);
    });
    withEnv({ DISABLE_REASONING_TASKS: " chat , summary " }, () => {
        assertEquals(reasoningDisabled("chat"), true);
        assertEquals(reasoningDisabled("summary"), true);
        assertEquals(reasoningDisabled("utility"), false);
    });
    withEnv({ DISABLE_REASONING_TASKS: "" }, () => {
        assertEquals(reasoningDisabled("chat"), false);
    });
})
