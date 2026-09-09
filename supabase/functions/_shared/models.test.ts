import { assertEquals } from "jsr:@std/assert@1.0.14";
import { modelFor, MODELS, STOCK_MODELS } from "./models.ts";

function withEnv(vars: Record<string, string>, body: () => void) {
    for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
    try {
        body();
    } finally {
        for (const k of Object.keys(vars)) Deno.env.delete(k);
    }
}

Deno.test("a task runs its default until its secret is set", () => {
    assertEquals(modelFor("distill"), MODELS.distill.default);
    withEnv({ DISTILL_MODEL: "google/gemini-3.1-flash-lite" }, () => {
        assertEquals(modelFor("distill"), "google/gemini-3.1-flash-lite");
    });
});

Deno.test("a beat follows the chat model unless told otherwise", () => {
    assertEquals(modelFor("beat"), MODELS.beat.default);
    withEnv({ CHAT_MODEL: "openai/gpt-5.6-luna" }, () => {
        assertEquals(modelFor("beat"), "openai/gpt-5.6-luna");
        withEnv({ BEAT_MODEL: "deepseek/deepseek-v4-flash-0731" }, () => {
            assertEquals(modelFor("beat"), "deepseek/deepseek-v4-flash-0731");
        });
    });
});

Deno.test("the stock set is exactly what an unmodified client sends", () => {
    assertEquals(
        STOCK_MODELS,
        new Set(["anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5", "anthropic/claude-sonnet-5", "openai/gpt-4o-transcribe"]),
    );
});

Deno.test("every switchable model has a distinct secret", () => {
    const secrets = Object.values(MODELS).map((slot) => slot.secret).filter(Boolean);
    assertEquals(new Set(secrets).size, secrets.length);
});
