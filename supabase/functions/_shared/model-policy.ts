// How a client's model choice is routed. Which models exist, and which secret
// switches each, is `models.ts`; this file only applies that table to a
// request.
//
// A request carrying a stock id (the client's own default for the task) is an
// unmodified client and is re-routed to what the table says the task runs.
// Anything else is an explicit user override (`defaults write com.example.nod
// openrouter.model …`) and is passed through untouched.

import { modelFor, MODELS, STOCK_MODELS } from "./models.ts";

export const ROUTING_VERSION = "2026-10-cost-v1";

const ROUTED_TASKS = ["summary", "title", "utility", "chat"] as const;
type RoutingTask = typeof ROUTED_TASKS[number];

/// What the table says this task runs today, or undefined for a task the
/// table does not route.
function taskModelOverride(task: string): string | undefined {
    const routed = ROUTED_TASKS.find((t) => t === task) as RoutingTask | undefined;
    return routed ? modelFor(routed) : undefined;
}

/// Tasks whose reasoning is forced off: the ones the table marks
/// `reasoningOff`, plus any named in `DISABLE_REASONING_TASKS` (a
/// comma-separated `task` list, the no-deploy lever). The client turns
/// reasoning off for `utility` alone and cannot be changed without a desktop
/// release. Measured on the sandbox chat key over 30 days: 529k of 650k
/// completion tokens were reasoning nobody read.
export function reasoningDisabled(task: string): boolean {
    const routed = ROUTED_TASKS.find((t) => t === task) as RoutingTask | undefined;
    if (routed && MODELS[routed].reasoningOff) return true;
    const raw = Deno.env.get("DISABLE_REASONING_TASKS");
    return raw ? raw.split(",").some((entry) => entry.trim() === task) : false;
}

export function applyReasoningPolicy(payload: Record<string, unknown>, task: string): Record<string, unknown> {
    if (reasoningDisabled(task)) return { ...payload, reasoning: { enabled: false } };
    if (task !== "summary") return payload;
    const effort = Deno.env.get("SUMMARY_REASONING_EFFORT");
    if (effort !== "low" && effort !== "medium") return { ...payload, reasoning: { enabled: false } };
    const cap = typeof payload.max_tokens === "number" && payload.max_tokens > 0
        ? Math.min(payload.max_tokens, 16000) : 16000;
    return { ...payload, reasoning: { effort }, max_tokens: cap };
}

const MAX_FALLBACK_CHAIN = 3;

interface RoutedModel {
    payload: Record<string, unknown>;
    routed: string;
}

/// Swap in the policy model, keeping the client's own chain behind it so a bad
/// policy value degrades to today's behavior instead of failing the call.
export function applyModelPolicy(
    payload: Record<string, unknown>,
    task: string,
    requested: string,
): RoutedModel {
    const override = taskModelOverride(task);
    if (!override || override === requested || !STOCK_MODELS.has(requested)) {
        return { payload, routed: requested };
    }

    const clientChain = Array.isArray(payload.models) ? payload.models.filter((m) => typeof m === "string") : [];
    // OpenRouter rejects a `models` array longer than this outright (HTTP 400),
    // and the client already sends up to three, so prepending the policy model
    // has to drop the least-wanted tail rather than grow the chain.
    const chain = [override, ...clientChain.filter((m) => m !== override)].slice(0, MAX_FALLBACK_CHAIN);
    return { payload: { ...payload, model: override, models: chain }, routed: override };
}

// Every chat completion that leaves for OpenRouter carries this; the audio
// transcription endpoint does not take `provider` and goes without. `zdr`
// limits routing to endpoints OpenRouter lists as zero-data-retention
// (first-party Anthropic, OpenAI and Google AI Studio are not on that list;
// Bedrock, Vertex and Azure are), so the privacy claim is enforced by the
// request rather than by an account toggle nobody can see from the code.
// `quantizations` turns away hosts that label themselves fp4 or lower.
// "unknown" has to stay, because first-party endpoints report nothing, which
// means an unlabelled host passes too; the floor is a filter, not a pin. A
// client's own `order`/`ignore` (Vertex over AI Studio) is kept.
const PROVIDER_FLOOR = {
    zdr: true,
    quantizations: ["unknown", "bf16", "fp16", "fp8"],
} as const;

export function withProviderFloor(payload: Record<string, unknown>): Record<string, unknown> {
    const own = payload.provider && typeof payload.provider === "object" ? payload.provider as Record<string, unknown> : {};
    return { ...payload, provider: { ...own, ...PROVIDER_FLOOR } };
}

// STT has no `task` field and no fallback chain, so it is routed on its own:
// the stock transcription id is replaced by the table's choice, a user override
// is passed through. The client picks `response_format` from the model it
// thinks it is talking to, so a swap across the Whisper line re-picks it here:
// Whisper needs `verbose_json` for segments and language, the others reject it.
export function applySttModelPolicy(payload: Record<string, unknown>): Record<string, unknown> {
    const override = modelFor("stt");
    if (override === payload.model || payload.model !== MODELS.stt.stock) return payload;
    const responseFormat = override.includes("whisper") ? "verbose_json" : "json";
    return { ...payload, model: override, response_format: responseFormat };
}

// Everything reaches the models through OpenRouter. The direct Groq and OpenAI
// Whisper paths are kept only behind an explicit mode for an outage, and can
// never serve `gpt-4o-transcribe` anyway.
type SttRoutingMode = "groq_primary" | "openrouter_primary" | "openrouter_only";

export function sttRoutingMode(): SttRoutingMode {
    const raw = Deno.env.get("STT_ROUTING_MODE");
    if (raw === "groq_primary" || raw === "openrouter_primary") return raw;
    return "openrouter_only";
}

// Anthropic and Google bill explicit cache writes; OpenAI caches automatically
// and rejects the marker, so a model routed to it must not carry one.
const CACHEABLE_MODEL_PREFIXES = ["anthropic/", "google/"];

export function supportsExplicitPromptCache(model: unknown): boolean {
    return typeof model === "string" && CACHEABLE_MODEL_PREFIXES.some((p) => model.startsWith(p));
}
