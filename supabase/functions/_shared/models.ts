// Every model Nod consumes, in one place.
//
// `default` is what runs today. Change it here and deploy, or set the entry's
// secret to change it without a deploy; the secret wins while it is set, so
// unset it once the default has caught up, or this file stops being true.
// `stock` is what an unmodified desktop client sends for the task; the proxy
// recognises that id and replaces it with `default`. A person's own
// `defaults write com.example.nod openrouter.model …` is anything else and is
// passed through untouched, so switching models never needs a desktop release.
//
// Every chat completion sent to OpenRouter carries `withProviderFloor` from
// `model-policy.ts`: zero-data-retention endpoints only, and no host that
// labels itself below fp8. Check https://openrouter.ai/api/v1/endpoints/zdr
// before choosing a chat model; one with no ZDR endpoint fails every request.
// Transcription is the exception: OpenRouter's audio endpoint takes no
// `provider` field, and `gpt-4o-transcribe` has no ZDR endpoint listed, so
// audio is the one path with no retention floor in code. `serves` is the ZDR
// endpoint a chat model was chosen for; routing is by price among the
// endpoints that pass the floor, so a model with many hosts may land elsewhere.

export type ModelTask =
    | "summary"
    | "title"
    | "utility"
    | "chat"
    | "stt"
    | "distill"
    | "beat"
    | "briefing"
    | "shareAsk"
    | "speechScript"
    | "tts"
    | "realtime"
    | "embedding";

export interface ModelSlot {
    /// What runs today when the secret is unset.
    default: string;
    /// The secret that overrides `default` until the next deploy. Absent for a
    /// model that cannot be switched without code.
    secret?: string;
    /// The id an unmodified desktop client sends; replaced by `default`.
    stock?: string;
    /// A secret whose value stands in when this task's own secret is unset.
    fallbackSecret?: string;
    /// Where the request goes.
    via: "openrouter" | "openai" | "edge-runtime";
    /// The ZDR endpoint this choice was made for, and the list price there.
    serves?: string;
    /// Who asks for it and how often, in one line.
    purpose: string;
    /// The task has nothing to work out, so a chain of thought is output
    /// billed for nobody; the proxy forces it off whatever the client asked.
    reasoningOff?: boolean;
}

export const MODELS: Record<ModelTask, ModelSlot> = {
    summary: {
        default: "anthropic/claude-sonnet-5",
        secret: "SUMMARY_MODEL",
        stock: "anthropic/claude-sonnet-4.6",
        via: "openrouter",
        serves: "Vertex or Bedrock, $2 / $10 per M tokens; a third cheaper than the 4.6 it replaced",
        purpose: "The session recap. One long call per session; the largest share of LLM spend.",
    },
    title: {
        default: "mistralai/mistral-small-2603",
        secret: "TITLE_MODEL",
        stock: "anthropic/claude-sonnet-4.6",
        via: "openrouter",
        serves: "Mistral first-party (FR), $0.15 / $0.60 per M tokens; about 20x cheaper than the Sonnet 4.6 it replaced",
        purpose: "The session title: 4-7 words from the recap's first section. One short call per session.",
        reasoningOff: true,
    },
    utility: {
        default: "mistralai/mistral-small-2603",
        secret: "UTILITY_MODEL",
        stock: "anthropic/claude-haiku-4.5",
        via: "openrouter",
        serves: "Mistral first-party (FR), $0.15 / $0.60 per M tokens; about 7x cheaper than Haiku 4.5",
        purpose: "Structured helpers: HyDE rewrite, session router, live analyst, lookups. Many small JSON calls.",
        reasoningOff: true,
    },
    chat: {
        default: "anthropic/claude-sonnet-5",
        secret: "CHAT_MODEL",
        stock: "anthropic/claude-sonnet-5",
        via: "openrouter",
        serves: "Vertex or Bedrock, $2 / $10 per M tokens, cache reads at $0.20",
        purpose: "Session chat and Ask Nod. Long cached prompts; the one place a person judges quality directly.",
    },
    stt: {
        default: "openai/gpt-4o-transcribe",
        secret: "STT_MODEL",
        stock: "openai/gpt-4o-transcribe",
        via: "openrouter",
        serves: "OpenRouter's STT endpoint; kept over Whisper because it preserves mixed-language speech as spoken",
        purpose: "Transcription and dictation, one call per voice chunk.",
    },
    distill: {
        default: "mistralai/mistral-small-2603",
        secret: "DISTILL_MODEL",
        via: "openrouter",
        serves: "Mistral first-party (FR), $0.15 / $0.60 per M tokens",
        purpose: "Turns a session into knowledge entries and claims. Background, one call per session.",
    },
    beat: {
        default: "deepseek/deepseek-v4-flash-0731",
        secret: "BEAT_MODEL",
        fallbackSecret: "CHAT_MODEL",
        via: "openrouter",
        serves: "DeepInfra fp8 (US), $0.06 / $0.18 per M tokens",
        purpose: "Beat reports written by the server while the Mac is asleep, from memory only. A beat that runs while the app is awake uses the chat model and its tools.",
    },
    briefing: {
        default: "deepseek/deepseek-v4-flash-0731",
        secret: "BRIEFING_MODEL",
        via: "openrouter",
        serves: "DeepInfra fp8 (US), $0.06 / $0.18 per M tokens",
        purpose: "The pre-meeting briefing written by calendar-sync. Background.",
    },
    shareAsk: {
        default: "openai/gpt-4o-mini",
        secret: "SHARE_ASK_MODEL",
        via: "openrouter",
        serves: "Azure, $0.15 / $0.60 per M tokens",
        purpose: "Questions asked on a public share page by someone who is not the owner.",
    },
    speechScript: {
        default: "openai/gpt-4o-mini",
        secret: "SPEECH_SCRIPT_MODEL",
        via: "openrouter",
        serves: "Azure, $0.15 / $0.60 per M tokens",
        purpose: "Rewrites an answer into a short script before it is spoken aloud.",
    },
    tts: {
        default: "gpt-4o-mini-tts",
        secret: "TTS_MODEL",
        via: "openai",
        purpose: "Speech synthesis for spoken answers, OpenAI direct. Billed per character.",
    },
    realtime: {
        default: "gpt-realtime-2",
        secret: "REALTIME_MODEL",
        via: "openai",
        purpose: "Live voice conversation from the notch. The client connects to OpenAI directly with a token this server mints.",
    },
    embedding: {
        default: "gte-small",
        via: "edge-runtime",
        purpose: "Search embeddings, computed inside the Edge runtime. No upstream bill, not switchable by secret.",
    },
};

/// The model to use for a task right now: its secret, then its fallback
/// secret, then the default.
export function modelFor(task: ModelTask): string {
    const slot = MODELS[task];
    const own = slot.secret ? Deno.env.get(slot.secret) : undefined;
    if (own) return own;
    const shared = slot.fallbackSecret ? Deno.env.get(slot.fallbackSecret) : undefined;
    return shared || slot.default;
}

/// Every id an unmodified desktop client can send.
export const STOCK_MODELS: ReadonlySet<string> = new Set(
    Object.values(MODELS).map((slot) => slot.stock).filter((id): id is string => Boolean(id)),
);
