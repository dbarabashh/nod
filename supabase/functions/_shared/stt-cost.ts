import { isObject } from "./http.ts";
import type { adminClient } from "./supabase.ts";

// What a transcription cost. OpenRouter reports its own figure per request and
// that always wins; providers that report nothing are priced from the rate card
// in `app_config.stt_rates`, which the monthly reconciliation cron reads too.

const PCM_BYTES_PER_SECOND = 32_000;
const WAV_HEADER_BYTES     = 44;


// STT providers (Groq, OpenAI, OpenRouter) don't return a per-request cost the
// way OpenRouter's chat endpoint does, so we estimate it from the audio
// duration × a per-provider rate. The rate card lives in `app_config.stt_rates`
// (not a code constant) so a provider price change is a one-row UPDATE, not a
// redeploy — and the monthly reconciliation cron reads the same source. Shape:
//   { "<provider>": { "default": <$/h>, "min_billed_seconds": <int>,
//                     "models": { "<model id>": <$/h> } } }
// `min_billed_seconds` captures provider billing floors (Groq bills a 10s
// minimum per request; our VAD segments average ~5s, so raw duration would
// understate cost ~2x). `models` overrides the per-provider default for a
// specific model id; OpenAI always serves whisper-1 so its default ($0.36/h)
// covers every requested id.
interface SttProviderRates {
    default: number;
    min_billed_seconds?: number;
    models?: Record<string, number>;
}
export type SttRates = Record<string, SttProviderRates>;

// Used only when app_config is unreadable — Groq large-v3 list price + 10s floor.
const STT_RATES_FALLBACK: SttRates = {
    groq: { default: 0.111, min_billed_seconds: 10, models: { "openai/whisper-large-v3-turbo": 0.04, "openai/whisper-large-v3": 0.111 } },
    openai: { default: 0.36, min_billed_seconds: 0 },
    openrouter: { default: 0.111, min_billed_seconds: 0, models: { "openai/whisper-large-v3-turbo": 0.04, "openai/whisper-large-v3": 0.111 } },
};

let cachedSttRates: { value: SttRates; at: number } | null = null;
const STT_RATES_TTL_MS = 60_000;

export async function sttRates(admin: ReturnType<typeof adminClient>): Promise<SttRates> {
    const now = Date.now();
    if (cachedSttRates && now - cachedSttRates.at < STT_RATES_TTL_MS) return cachedSttRates.value;
    // `app_config` stopped being a singleton in `mobile_platform_support`
    // (2026-08-06) and is now keyed by platform; the old `.eq("singleton", true)`
    // filter errored on every call, which this function silently treated as
    // "use the hardcoded fallback". Provider pricing is the same for both rows,
    // so the desktop row is the card.
    const { data, error } = await admin
        .from("app_config")
        .select("stt_rates")
        .eq("platform", "macos")
        .single();
    if (error) {
        console.error(`app_config.stt_rates unreadable, pricing from the hardcoded card: ${error.message}`);
    }
    const value = (!error && isObject(data) && isObject(data.stt_rates))
        ? data.stt_rates as SttRates
        : STT_RATES_FALLBACK;
    cachedSttRates = { value, at: now };
    return value;
}

// Estimated cost for one transcription. Returns null when we can't price the
// row (unknown provider) so it stays honestly empty rather than fabricated.
export function transcribeCostUsd(rates: SttRates, provider: string, model: string, audioSeconds: number | null): number | null {
    if (audioSeconds == null || audioSeconds <= 0) return null;
    // Fall back to the built-in card if a hand-edited config omits a provider,
    // so a provider that actually served still records a cost.
    const p = rates[provider] ?? STT_RATES_FALLBACK[provider];
    if (!p) return null;
    const rate = p.models?.[model] ?? p.default;
    if (typeof rate !== "number") return null;
    const floor = typeof p.min_billed_seconds === "number" ? p.min_billed_seconds : 0;
    const billedSeconds = Math.max(audioSeconds, floor);
    // Match the column precision: numeric(12, 6).
    return Math.round((billedSeconds / 3600) * rate * 1e6) / 1e6;
}

// The exact price the provider charged, when it says so. OpenRouter returns
// `usage.cost` on every STT response; Groq and OpenAI return none, so those stay
// on the rate-card estimate. Chat has always recorded the reported cost — this
// is what puts transcribe on the same footing.
export function reportedCostUsd(body: string): number | null {
    try {
        const parsed = JSON.parse(body);
        const cost = isObject(parsed) && isObject(parsed.usage) ? parsed.usage.cost : undefined;
        return typeof cost === "number" && Number.isFinite(cost) && cost >= 0 ? cost : null;
    } catch {
        return null;
    }
}

// Reverse the client's encoding: payload.input_audio.data is a base64 WAV.
// Decode → strip 44-byte header → divide by 32 kB/s. Returns null if the
// shape doesn't match (defensive; the Swift client always sends WAV).
// 16 kHz × 16-bit × mono == 32_000 bytes per second of audio. The client
// always normalises to this format before posting (see WhisperTranscriber),
// so we can recover the duration from the base64-decoded byte count + the WAV
// header (44 bytes). Off by ≤0.1% — fine for cost accounting.
export function audioSecondsFromPayload(payload: unknown): number | null {
    if (!isObject(payload)) return null;
    const inputAudio = payload.input_audio;
    if (!isObject(inputAudio) || typeof inputAudio.data !== "string") return null;
    try {
        // base64 length × 3/4 — we only need the byte count, not the bytes.
        const b64 = inputAudio.data;
        const padding = (b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0);
        const byteCount = Math.floor((b64.length * 3) / 4) - padding;
        const pcmBytes = Math.max(0, byteCount - WAV_HEADER_BYTES);
        return Math.round((pcmBytes / PCM_BYTES_PER_SECOND) * 1000) / 1000;
    } catch {
        return null;
    }
}

