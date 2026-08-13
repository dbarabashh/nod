import { isObject } from "./http.ts";
import { sttRoutingMode } from "./model-policy.ts";

// Everything about reaching a speech-to-text provider: the chain, what counts
// as worth failing over, and the record of what failed on the way. The proxy
// only asks for a transcript and is told which provider produced it.

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");
const GROQ_API_KEY = Deno.env.get("GROQ_API_KEY");
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

const OPENROUTER_TRANSCRIBE_URL = "https://openrouter.ai/api/v1/audio/transcriptions";
const GROQ_TRANSCRIBE_URL = "https://api.groq.com/openai/v1/audio/transcriptions";
const OPENAI_TRANSCRIBE_URL = "https://api.openai.com/v1/audio/transcriptions";

const TRANSCRIBE_TIMEOUT_MS = 60_000;

// Startup diagnostic: prints once per cold start which STT provider keys the
// function can actually see. `set`/`MISSING` only — never the value. If this
// logs `groq=MISSING` while the dashboard shows a GROQ_API_KEY secret, the name
// doesn't match what the code reads (Deno.env.get("GROQ_API_KEY")).
console.log(`[stt] provider keys: groq=${GROQ_API_KEY ? "set" : "MISSING"} openai=${OPENAI_API_KEY ? "set" : "MISSING"} openrouter=${OPENROUTER_API_KEY ? "set" : "MISSING"}`);

// `reason` separates a real upstream HTTP status from one we synthesized
// locally: a 504 we invented on our own abort is a different failure class from
// a 504 the provider actually returned, and the whole point of the failover
// record is telling those apart.
type FailureReason = "http" | "timeout" | "network";

interface CallResult {
    status: number;
    text: string;
    reason?: FailureReason;
    retryAfter?: string | null;
    ms?: number;
    // Internal-only: recorded in the failover trail, never returned to the client.
    detail?: string;
}

export interface FailoverAttempt {
    provider: string;
    status: number;
    reason: FailureReason;
    ms: number | null;
    retry_after: string | null;
    body: string | null;
}

interface STTResult extends CallResult { provider: string; failover: FailoverAttempt[] }

// An OpenAI-compatible multipart STT endpoint. Groq and OpenAI both speak this
// shape; only the model-id mapping and host differ. OpenRouter is NOT one of
// these — it takes base64-JSON and is handled by the legacy `callOpenRouter`
// path as the terminal fallback.
interface STTProvider {
    name: string;
    url: string;
    apiKey: string;
    // Whether this provider hosts the requested model at all. A provider handed
    // a model it doesn't serve answers 400/404, and `shouldFailover` correctly
    // refuses to retry those — so leaving it in the chain fails the whole
    // request instead of standing aside for one that can serve it. Both entries
    // here are Whisper-only: neither hosts `gpt-4o-transcribe`.
    serves: (clientModel: string) => boolean;
    mapModel: (clientModel: string) => string;
}

const isWhisperModel = (m: string) => m.includes("whisper");

// Multipart provider chain in priority order, filtered to those whose key is
// configured and that can serve `model`. Empty until GROQ_API_KEY /
// OPENAI_API_KEY land — that's the env-gated cutover: with neither set,
// `callTranscribe` uses OpenRouter alone, so this deploy changes nothing until
// the secret is added.
function sttMultipartChain(model: string): STTProvider[] {
    const chain: STTProvider[] = [];
    if (GROQ_API_KEY) {
        chain.push({
            name: "groq",
            url: GROQ_TRANSCRIBE_URL,
            apiKey: GROQ_API_KEY,
            serves: isWhisperModel,
            // The client sends OpenRouter-style vendor-prefixed ids
            // ("openai/whisper-large-v3-turbo"); Groq hosts the same weights
            // under the bare id.
            mapModel: (m) => m.replace(/^openai\//, ""),
        });
    }
    if (OPENAI_API_KEY) {
        chain.push({
            name: "openai",
            url: OPENAI_TRANSCRIBE_URL,
            apiKey: OPENAI_API_KEY,
            serves: isWhisperModel,
            // OpenAI's transcription API only exposes whisper-1 (large-v2). Used
            // purely as a reliability fallback when Groq rate-limits/stalls — not
            // for output parity with Groq's large-v3.
            mapModel: () => "whisper-1",
        });
    }
    return chain.filter((p) => p.serves(model));
}

// Statuses worth failing over to the next provider. Beyond 429/5xx we also fail
// over on 401/403 (a rotated/over-quota key on ONE provider must not take down
// transcription when another is configured) and 408 (request timeout). We do
// NOT fail over on a genuine bad request (400/404/422) — that fails the same way
// everywhere, so surfacing it is correct.
function shouldFailover(status: number): boolean {
    return status === 401 || status === 403 || status === 408 ||
        status === 409 || status === 429 || status >= 500;
}

// base64 → bytes. `atob` is a Deno global; `Uint8Array.from(str, map)` avoids an
// explicit per-char JS loop over the (up to ~2 MB) WAV on the CPU-budgeted edge
// worker. The client always posts a complete standard-base64 WAV.
function decodeBase64(b64: string): Uint8Array<ArrayBuffer> {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

// One attempt against OpenRouter's STT endpoint, in the same shape a
// multipart-chain attempt returns — so both call sites can push it onto the
// same `failover` trail with `failoverAttempt`.
function callOpenRouterSTT(payload: unknown, userId: string): Promise<CallResult> {
    return callOpenRouter(OPENROUTER_TRANSCRIBE_URL, payload, TRANSCRIBE_TIMEOUT_MS, userId, "transcribe");
}

// Transcribe via the provider chain. Order depends on `sttRoutingMode()`:
//
//   groq_primary (default) — each multipart provider (Groq, then OpenAI if
//     configured), then OpenRouter as the terminal fallback. Unchanged from
//     before PR 2.
//   openrouter_primary — OpenRouter first; on a failover-eligible status,
//     fall through to the multipart chain exactly as above. Groq becomes the
//     emergency path instead of OpenRouter.
//   openrouter_only — OpenRouter alone, no direct-provider fallback at all.
//     Diagnostic only; see the plan for why this must not become the
//     production default while direct Groq is still the outage escape hatch.
//
// Returns which provider actually served, for usage attribution.
export async function callTranscribe(payload: unknown, userId: string): Promise<STTResult> {
    const failover: FailoverAttempt[] = [];
    const mode = sttRoutingMode();
    const model = isObject(payload) && typeof payload.model === "string" ? payload.model : "";

    let last: STTResult | null = null;

    if (mode === "openrouter_primary" || mode === "openrouter_only") {
        if (!OPENROUTER_API_KEY) {
            return { status: 502, text: JSON.stringify({ error: "no STT provider configured" }), provider: "none", failover };
        }
        const r = await callOpenRouterSTT(payload, userId);
        if (!shouldFailover(r.status) || mode === "openrouter_only") {
            return { ...r, provider: "openrouter", failover };
        }
        failover.push(failoverAttempt("openrouter", r));
        console.warn(
            `transcribe provider=openrouter status=${r.status} reason=${r.reason ?? "http"} retry_after=${r.retryAfter ?? "-"} dt=${r.ms ?? "?"}ms — failing over to direct Groq`,
        );
        // Kept so a model no direct provider serves reports OpenRouter's own
        // failure rather than a synthetic "nothing configured".
        last = { ...r, provider: "openrouter", failover };
    }

    for (const p of sttMultipartChain(model)) {
        const r = await callMultipartSTT(p, payload, userId);
        if (!shouldFailover(r.status)) return { ...r, provider: p.name, failover };
        failover.push(failoverAttempt(p.name, r));
        console.warn(
            `transcribe provider=${p.name} status=${r.status} reason=${r.reason ?? "http"} retry_after=${r.retryAfter ?? "-"} dt=${r.ms ?? "?"}ms — failing over`,
        );
        last = { ...r, provider: p.name, failover };
    }

    // groq_primary's own terminal fallback: OpenRouter, only if it wasn't
    // already tried as primary above.
    if (mode === "groq_primary" && OPENROUTER_API_KEY) {
        const r = await callOpenRouterSTT(payload, userId);
        return { ...r, provider: "openrouter", failover };
    }
    return last ?? { status: 502, text: JSON.stringify({ error: "no STT provider configured" }), provider: "none", failover };
}

// The upstream body is the evidence that separates "429, retry in 8s" from
// "429, daily token quota exhausted" — two failures with opposite fixes. Only
// bodies of FAILED attempts are stored, so no transcript text can land here.
const FAILOVER_BODY_LIMIT = 300;

function failoverAttempt(provider: string, r: CallResult): FailoverAttempt {
    return {
        provider,
        status: r.status,
        reason: r.reason ?? "http",
        ms: r.ms ?? null,
        retry_after: r.retryAfter ?? null,
        body: (r.detail ?? r.text)?.slice(0, FAILOVER_BODY_LIMIT) ?? null,
    };
}

// POST the audio to an OpenAI-compatible multipart endpoint. The client→proxy
// contract stays base64-JSON (provider-agnostic); the translation to a file
// upload happens here so swapping providers never touches the client.
async function callMultipartSTT(p: STTProvider, payload: unknown, userId: string): Promise<CallResult> {
    if (!isObject(payload)) {
        return { status: 400, text: JSON.stringify({ error: "transcribe payload must be an object" }) };
    }
    const inputAudio = isObject(payload.input_audio) ? payload.input_audio : null;
    if (!inputAudio || typeof inputAudio.data !== "string") {
        return { status: 400, text: JSON.stringify({ error: "transcribe payload missing input_audio.data" }) };
    }

    let bytes: Uint8Array<ArrayBuffer>;
    try {
        bytes = decodeBase64(inputAudio.data);
    } catch {
        return { status: 400, text: JSON.stringify({ error: "input_audio.data is not valid base64" }) };
    }

    const format = typeof inputAudio.format === "string" ? inputAudio.format : "wav";
    const model = typeof payload.model === "string" ? p.mapModel(payload.model) : "whisper-large-v3";

    const form = new FormData();
    form.append("file", new Blob([bytes], { type: `audio/${format}` }), `audio.${format}`);
    form.append("model", model);
    if (typeof payload.language === "string" && payload.language.length > 0) form.append("language", payload.language);
    if (typeof payload.prompt === "string" && payload.prompt.length > 0) form.append("prompt", payload.prompt);
    if (typeof payload.temperature === "number") form.append("temperature", String(payload.temperature));
    if (typeof payload.response_format === "string") form.append("response_format", payload.response_format);
    if (Array.isArray(payload.timestamp_granularities)) {
        for (const g of payload.timestamp_granularities) {
            if (typeof g === "string") form.append("timestamp_granularities[]", g);
        }
    }

    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TRANSCRIBE_TIMEOUT_MS);
    try {
        // Note: no Content-Type header — fetch derives the multipart boundary
        // from the FormData body. Setting it manually breaks the upload.
        const upstream = await fetch(p.url, {
            method: "POST",
            headers: { "Authorization": `Bearer ${p.apiKey}` },
            body: form,
            signal: controller.signal,
        });
        const text = await upstream.text();
        const dt = Date.now() - started;
        console.log(`transcribe user=${userId} provider=${p.name} model=${model} status=${upstream.status} dt=${dt}ms bytes=${text.length}`);
        return { status: upstream.status, text, reason: "http", retryAfter: upstream.headers.get("retry-after"), ms: dt };
    } catch (error) {
        const dt = Date.now() - started;
        if (error instanceof DOMException && error.name === "AbortError") {
            console.error(`transcribe provider=${p.name} user=${userId} timeout after ${dt}ms`);
            return { status: 504, text: JSON.stringify({ error: `Upstream timeout (${TRANSCRIBE_TIMEOUT_MS}ms)` }), reason: "timeout", ms: dt };
        }
        console.error(`transcribe provider=${p.name} user=${userId} upstream error: ${error}`);
        return { status: 502, text: JSON.stringify({ error: "Upstream request failed" }), reason: "network", ms: dt, detail: String(error) };
    } finally {
        clearTimeout(timer);
    }
}

async function callOpenRouter(
    url: string,
    payload: unknown,
    timeoutMs: number,
    userId: string,
    label: string,
): Promise<CallResult> {
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
        const upstream = await fetch(url, {
            method: "POST",
            headers: {
                "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                "X-Title": "Nod",
            },
            body: JSON.stringify(payload),
            signal: controller.signal,
        });

        const text = await upstream.text();
        const dt = Date.now() - started;
        console.log(`${label} user=${userId} status=${upstream.status} dt=${dt}ms bytes=${text.length}`);

        return { status: upstream.status, text, reason: "http", retryAfter: upstream.headers.get("retry-after"), ms: dt };
    } catch (error) {
        const dt = Date.now() - started;
        if (error instanceof DOMException && error.name === "AbortError") {
            console.error(`${label} user=${userId} timeout after ${dt}ms`);
            return { status: 504, text: JSON.stringify({ error: `Upstream timeout (${timeoutMs}ms)` }), reason: "timeout", ms: dt };
        }
        console.error(`${label} user=${userId} upstream error: ${error}`);
        return { status: 502, text: JSON.stringify({ error: "Upstream request failed" }), reason: "network", ms: dt, detail: String(error) };
    } finally {
        clearTimeout(timer);
    }
}

