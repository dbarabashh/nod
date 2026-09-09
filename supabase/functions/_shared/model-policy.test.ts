import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
    applyModelPolicy,
    applySttModelPolicy,
    reasoningDisabled,
    sttRoutingMode,
    supportsExplicitPromptCache,
    withProviderFloor,
} from "./model-policy.ts";
import { MODELS } from "./models.ts";

function withEnv(vars: Record<string, string>, body: () => void) {
    for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
    try {
        body();
    } finally {
        for (const k of Object.keys(vars)) Deno.env.delete(k);
    }
}

const payload = { model: "anthropic/claude-sonnet-4.6", models: ["anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"] };

Deno.test("a stock client runs what the table says, with no secret set", () => {
    const r = applyModelPolicy(payload, "summary", "anthropic/claude-sonnet-4.6");
    assertEquals(r.routed, MODELS.summary.default);
    assertEquals(r.payload.model, MODELS.summary.default);
});

Deno.test("a stock id that already matches the table passes through unchanged", () => {
    const chat = { model: "anthropic/claude-sonnet-5", models: ["anthropic/claude-sonnet-5"] };
    const r = applyModelPolicy(chat, "chat", "anthropic/claude-sonnet-5");
    assertEquals(r.routed, "anthropic/claude-sonnet-5");
    assertEquals(r.payload, chat);
});

Deno.test("a secret re-routes a stock client default", () => {
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
    withEnv({ SUMMARY_MODEL: "openai/gpt-5.6-luna" }, () => {
        const r = applyModelPolicy(payload, "title", "anthropic/claude-sonnet-4.6");
        assertEquals(r.routed, MODELS.title.default);
    });
});

Deno.test("an unknown task is never re-routed", () => {
    withEnv({ SUMMARY_MODEL: "anthropic/claude-sonnet-5" }, () => {
        const r = applyModelPolicy(payload, "unknown", "anthropic/claude-sonnet-4.6");
        assertEquals(r.routed, "anthropic/claude-sonnet-4.6");
    });
});

Deno.test("stt routing is openrouter only unless a direct path is asked for", () => {
    assertEquals(sttRoutingMode(), "openrouter_only");
    withEnv({ STT_ROUTING_MODE: "nonsense" }, () => assertEquals(sttRoutingMode(), "openrouter_only"));
    withEnv({ STT_ROUTING_MODE: "groq_primary" }, () => assertEquals(sttRoutingMode(), "groq_primary"));
    withEnv({ STT_ROUTING_MODE: "openrouter_primary" }, () => assertEquals(sttRoutingMode(), "openrouter_primary"));
});

Deno.test("only anthropic and google take an explicit cache marker", () => {
    assertEquals(supportsExplicitPromptCache("anthropic/claude-sonnet-5"), true);
    assertEquals(supportsExplicitPromptCache("google/gemini-3.1-flash-lite"), true);
    assertEquals(supportsExplicitPromptCache("openai/gpt-5.6-luna"), false);
    assertEquals(supportsExplicitPromptCache(undefined), false);
});

Deno.test("the table turns reasoning off for the tasks that have nothing to think about", () => {
    assertEquals(reasoningDisabled("title"), true);
    assertEquals(reasoningDisabled("utility"), true);
    assertEquals(reasoningDisabled("summary"), false);
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
        assertEquals(reasoningDisabled("distill"), false);
    });
    withEnv({ DISABLE_REASONING_TASKS: "" }, () => {
        assertEquals(reasoningDisabled("chat"), false);
    });
})

Deno.test("every request carries the zdr and precision floor", () => {
    const out = withProviderFloor({ model: "x", messages: [] });
    assertEquals(out.provider, { zdr: true, quantizations: ["unknown", "bf16", "fp16", "fp8"] });
});

Deno.test("the floor keeps the client's own provider order", () => {
    const out = withProviderFloor({ model: "google/x", provider: { order: ["google-vertex"], ignore: ["google-ai-studio"], allow_fallbacks: true } });
    assertEquals(out.provider, {
        order: ["google-vertex"],
        ignore: ["google-ai-studio"],
        allow_fallbacks: true,
        zdr: true,
        quantizations: ["unknown", "bf16", "fp16", "fp8"],
    });
});

Deno.test("the floor cannot be lowered by a client", () => {
    const out = withProviderFloor({ provider: { zdr: false, quantizations: ["fp4"] } });
    assertEquals((out.provider as Record<string, unknown>).zdr, true);
    assertEquals((out.provider as Record<string, unknown>).quantizations, ["unknown", "bf16", "fp16", "fp8"]);
});

Deno.test("stt policy replaces the stock transcription model only", () => {
    const stock = { model: "openai/gpt-4o-transcribe", file: "..." };
    assertEquals(applySttModelPolicy(stock), stock, "the table runs the stock model today");
    withEnv({ STT_MODEL: "openai/gpt-4o-mini-transcribe" }, () => {
        assertEquals(applySttModelPolicy(stock).model, "openai/gpt-4o-mini-transcribe");
        assertEquals(applySttModelPolicy({ model: "openai/whisper-large-v3" }).model, "openai/whisper-large-v3");
    });
});

Deno.test("a stock request without a chain gets the routed model as its whole chain", () => {
    const r = applyModelPolicy({ model: "anthropic/claude-sonnet-4.6" }, "summary", "anthropic/claude-sonnet-4.6");
    assertEquals(r.payload.models, [MODELS.summary.default]);
});

Deno.test("a table task the proxy does not route is left alone", () => {
    const r = applyModelPolicy(payload, "distill", "anthropic/claude-sonnet-4.6");
    assertEquals(r.routed, "anthropic/claude-sonnet-4.6");
    assertEquals(r.payload, payload);
});

Deno.test("an stt swap across the whisper line re-picks the response format", () => {
    const stock = { model: "openai/gpt-4o-transcribe", response_format: "json" };
    withEnv({ STT_MODEL: "openai/whisper-large-v3" }, () => {
        assertEquals(applySttModelPolicy(stock).response_format, "verbose_json");
    });
    withEnv({ STT_MODEL: "openai/gpt-4o-mini-transcribe" }, () => {
        assertEquals(applySttModelPolicy(stock).response_format, "json");
    });
});
