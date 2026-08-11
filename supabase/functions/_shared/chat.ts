import { isObject, json } from "./http.ts";
import { applyModelPolicy, ROUTING_VERSION, supportsExplicitPromptCache } from "./model-policy.ts";
import { recordUsage } from "./usage.ts";

// Everything between the client's chat request and OpenRouter: prompt caching,
// the server-side model policy, and the two response shapes (one-shot and SSE
// passthrough). Both paths consume the upstream as a stream so a long but
// progressing generation is bounded by an idle watchdog rather than a fixed
// total timer.

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");
const OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";
const CHAT_TIMEOUT_MS = 30_000;

// The chat prompt's bulk — the meeting transcript + recap — rides in the system
// message. In the multi-turn Q&A chat it repeats verbatim on every turn, so
// marking it with a cache_control breakpoint lets Anthropic/Gemini serve that
// stable prefix from cache (~10% of input price) on later turns instead of
// re-billing it each question.
//
// Caching is OPT-IN via the client's `cache_prompt` flag, NOT applied to every
// `kind:chat` call. This is deliberate: the single-shot generation calls
// (summary, title, recap, entities — also `kind:chat`) each send a large, unique
// transcript prompt exactly once, so a cache_control marker there is a cache
// *write* (billed above base input) that's never read — a net surcharge. Only
// the true multi-turn chat sets the flag. The flag is internal, so it's stripped
// from the payload before forwarding upstream.
//
// (Sub-minimum prefixes — under 1k tokens on Sonnet, 4k on Haiku/Opus/Gemini Pro —
// are ignored upstream, so a marker on a small chat prompt is a harmless no-op.)
function applyPromptCaching(payload: Record<string, unknown>): Record<string, unknown> {
    const { cache_prompt, ...rest } = payload as Record<string, unknown> & { cache_prompt?: unknown };
    // Always drop the internal flag so it never reaches OpenRouter, regardless
    // of whether we end up marking the prompt.
    if (cache_prompt !== true || !supportsExplicitPromptCache(rest.model) || !Array.isArray(rest.messages)) {
        return rest;
    }
    let marked = false;
    const messages = (rest.messages as unknown[]).map((m) => {
        if (marked || !isObject(m) || m.role !== "system" || typeof m.content !== "string") return m;
        marked = true;
        return {
            ...m,
            content: [{ type: "text", text: m.content, cache_control: { type: "ephemeral" } }],
        };
    });
    return { ...rest, messages };
}

// Tells the client that routing substituted a model, and which one. Emitted
// only on a substitution, so its presence IS the signal — the same shape as
// `x-nod-stt-provider`. It reports what we asked the upstream for, not what
// finally served: the streaming path must send headers before the usage frame
// arrives, and what served is recorded in `usage_events.resolved_model` anyway.
function routingHeaders(requested: string, routed: string): Record<string, string> {
    return routed === requested ? {} : { "x-nod-model-routed": routed };
}

export async function forwardChat(rawPayload: unknown, userId: string): Promise<Response> {
    const model = isObject(rawPayload) && typeof rawPayload.model === "string" ? rawPayload.model : "unknown";
    // Which of the four routing categories this call belongs to (summary/
    // title/utility/chat) — the client derives it from which model property
    // resolved `model`, since single-shot generation calls otherwise look
    // identical to the proxy. Absent on any client built before this, so
    // "unknown" is a real, expected value, not an error.
    const task = isObject(rawPayload) && typeof rawPayload.task === "string" ? rawPayload.task : "unknown";

    if (!isObject(rawPayload)) {
        return json({ error: "invalid chat payload" }, 400);
    }

    // Strip the internal `task` field before it reaches the caching step or
    // upstream — same treatment as `cache_prompt`.
    const { task: _task, ...withoutTask } = rawPayload as Record<string, unknown> & { task?: unknown };

    // Route BEFORE deciding on caching: the cache_control marker is only valid
    // for some providers, and routing is exactly what can move a task onto one
    // that rejects it. Deciding first would mark a payload for a model that is
    // about to be replaced.
    const { payload: routedPayload, routed } = applyModelPolicy(withoutTask, task, model);
    if (routed !== model) {
        console.log(`routing user=${userId} task=${task} requested=${model} routed=${routed} policy=${ROUTING_VERSION}`);
    }

    // Apply prompt caching when the client opted in (`cache_prompt`), and strip
    // that internal flag before forwarding. Non-opted calls pass through
    // unchanged. The client still sends plain string message content; the
    // cache_control content-block rewrite happens here.
    const payload = applyPromptCaching(routedPayload);

    // Streaming path (used by "Suggest reply"): pass the upstream SSE through
    // verbatim so the client renders tokens as they arrive. Usage is captured
    // off a teed copy of the stream — see forwardChatStream.
    if (payload.stream === true) {
        return forwardChatStream(payload, userId, model, routed, task);
    }

    // One-shot path (typed chat question). We still consume OpenRouter as a
    // stream internally so the request is bounded by an idle watchdog, not the
    // old hard 30s total-duration cap — that cap 504'd chat whenever the
    // completion ran long (large-transcript meetings), even though tokens were
    // still flowing. The deltas are buffered back into the same one-shot JSON
    // the client already decodes, so the switch is invisible client-side.
    return forwardChatBuffered(payload, userId, model, routed, task);
}

// Non-streaming chat served over an internal stream. Requests SSE from
// OpenRouter (so a long-but-progressing generation isn't killed by a fixed
// total timer), accumulates the deltas, and returns the assembled completion
// as the one-shot `{ choices: [{ message: { content } }] }` envelope the Swift
// client decodes. `usage: { include: true }` makes the terminal chunk carry
// `usage.cost` for accounting.
async function forwardChatBuffered(payload: Record<string, unknown>, userId: string, model: string, routed: string, task: string): Promise<Response> {
    const enriched = {
        ...payload,
        stream: true,
        stream_options: { include_usage: true },
        usage: { include: true },
    };

    const started = Date.now();
    const controller = new AbortController();
    // Idle watchdog, matching forwardChatStream: abort only when the upstream
    // goes quiet for CHAT_TIMEOUT_MS (a hang before the first byte or a stall
    // mid-stream), never mid-answer while tokens are arriving.
    let lastActivity = Date.now();
    const watchdog = setInterval(() => {
        if (Date.now() - lastActivity > CHAT_TIMEOUT_MS) {
            console.warn(`chat-buffered user=${userId} idle >${CHAT_TIMEOUT_MS}ms — aborting`);
            controller.abort();
        }
    }, 5_000);

    try {
        let upstream: Response;
        try {
            upstream = await fetch(OPENROUTER_CHAT_URL, {
                method: "POST",
                headers: {
                    "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                    "Content-Type": "application/json",
                    "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                    "X-Title": "Nod",
                },
                body: JSON.stringify(enriched),
                signal: controller.signal,
            });
        } catch (error) {
            const aborted = error instanceof DOMException && error.name === "AbortError";
            console.error(`chat-buffered user=${userId} upstream ${aborted ? "timeout" : "error"}: ${error}`);
            return json({ error: aborted ? `Upstream timeout (idle ${CHAT_TIMEOUT_MS}ms)` : "Upstream request failed" }, aborted ? 504 : 502);
        }

        if (!upstream.ok || !upstream.body) {
            const text = await upstream.text().catch(() => "");
            console.error(`chat-buffered user=${userId} status=${upstream.status} (no stream body)`);
            return new Response(text || JSON.stringify({ error: "upstream error" }), {
                status: upstream.status || 502,
                headers: { "Content-Type": "application/json" },
            });
        }

        let assembled: BufferedChat;
        try {
            assembled = await readBufferedChat(upstream.body, () => { lastActivity = Date.now(); });
        } catch (error) {
            // The watchdog aborts the body read on an idle stall; a dropped
            // connection surfaces here too. Without this catch the rejection
            // escapes to Deno.serve as a generic 500 — defeating the 504 the
            // idle watchdog exists to return.
            const aborted = error instanceof DOMException && error.name === "AbortError";
            console.error(`chat-buffered user=${userId} stream ${aborted ? "timeout" : "error"}: ${error}`);
            return json({ error: aborted ? `Upstream timeout (idle ${CHAT_TIMEOUT_MS}ms)` : "Upstream stream failed" }, aborted ? 504 : 502);
        }
        const dt = Date.now() - started;
        console.log(`chat-buffered user=${userId} model=${model} status=${upstream.status} dt=${dt}ms chars=${assembled.content.length} tokens=${assembled.usage?.completion_tokens ?? "?"} prompt=${assembled.usage?.prompt_tokens ?? "?"} cached=${assembled.usage?.prompt_tokens_details?.cached_tokens ?? "?"}`);

        try {
            await recordUsage({
                user_id: userId,
                kind: "chat",
                model,
                status: upstream.status,
                prompt_tokens:     assembled.usage?.prompt_tokens     ?? null,
                completion_tokens: assembled.usage?.completion_tokens ?? null,
                generation_id:     assembled.id                       ?? null,
                cost_usd:          assembled.usage?.cost              ?? null,
                task,
                routing_version: ROUTING_VERSION,
                requested_model: model,
                resolved_model: assembled.model,
            });
        } catch (err) {
            console.warn(`chat usage record skipped: ${err}`);
        }

        // An upstream error can arrive as a 200 body carrying an `error` chunk
        // with no content — surface it as 502 rather than an empty completion.
        if (!assembled.content && assembled.error) {
            console.error(`chat-buffered user=${userId} stream error: ${assembled.error}`);
            return json({ error: assembled.error }, 502);
        }

        const responseBody = {
            id: assembled.id,
            model,
            choices: [{
                index: 0,
                message: { role: "assistant", content: assembled.content },
                finish_reason: assembled.finishReason ?? "stop",
            }],
            usage: assembled.usage,
        };
        return new Response(JSON.stringify(responseBody), {
            status: upstream.status,
            headers: { "Content-Type": "application/json", ...routingHeaders(model, routed) },
        });
    } finally {
        clearInterval(watchdog);
    }
}

// Streaming chat: forward OpenRouter's SSE body straight to the client while
// teeing a copy to capture usage from the terminal chunk. `stream_options.
// include_usage` (OpenAI-compat) makes OpenRouter append a final `usage` chunk
// before `[DONE]`; we parse it off the teed branch so accounting survives the
// stream without buffering the bytes the user is waiting on.
async function forwardChatStream(payload: Record<string, unknown>, userId: string, model: string, routed: string, task: string): Promise<Response> {
    const enriched = {
        ...payload,
        stream: true,
        stream_options: { include_usage: true },
        usage: { include: true },
    };

    const started = Date.now();
    const controller = new AbortController();
    // Idle watchdog, NOT a total-duration cap. A healthy stream can legitimately
    // run longer than CHAT_TIMEOUT_MS while delivering tokens — a fixed total
    // timer would abort mid-answer and truncate a long suggest-reply. Instead we
    // abort only when the upstream goes quiet for CHAT_TIMEOUT_MS, which covers
    // both a provider that hangs before the first byte and one that stalls
    // mid-stream. `lastActivity` is bumped per chunk from the meter callback.
    let lastActivity = Date.now();
    const watchdog = setInterval(() => {
        if (Date.now() - lastActivity > CHAT_TIMEOUT_MS) {
            console.warn(`chat-stream user=${userId} idle >${CHAT_TIMEOUT_MS}ms — aborting`);
            controller.abort();
        }
    }, 5_000);

    let upstream: Response;
    try {
        upstream = await fetch(OPENROUTER_CHAT_URL, {
            method: "POST",
            headers: {
                "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/dbarabashh/Nod",
                "X-Title": "Nod",
            },
            body: JSON.stringify(enriched),
            signal: controller.signal,
        });
    } catch (error) {
        clearInterval(watchdog);
        const aborted = error instanceof DOMException && error.name === "AbortError";
        console.error(`chat-stream user=${userId} upstream ${aborted ? "timeout" : "error"}: ${error}`);
        return json({ error: "Upstream request failed" }, aborted ? 504 : 502);
    }

    if (!upstream.ok || !upstream.body) {
        clearInterval(watchdog);
        const text = await upstream.text().catch(() => "");
        console.error(`chat-stream user=${userId} status=${upstream.status} (no stream body)`);
        return new Response(text || JSON.stringify({ error: "upstream error" }), {
            status: upstream.status || 502,
            headers: { "Content-Type": "application/json" },
        });
    }

    // One branch to the client, one to the usage meter. The meter runs in the
    // background; a logging failure must never disturb the streamed bytes.
    const [toClient, toMeter] = upstream.body.tee();
    const meter = (async () => {
        try {
            const usage = await readStreamUsage(toMeter, () => { lastActivity = Date.now(); });
            const dt = Date.now() - started;
            console.log(`chat-stream user=${userId} model=${model} status=${upstream.status} dt=${dt}ms tokens=${usage?.completion_tokens ?? "?"} prompt=${usage?.prompt_tokens ?? "?"} cached=${usage?.prompt_tokens_details?.cached_tokens ?? "?"}`);
            await recordUsage({
                user_id: userId,
                kind: "chat",
                model,
                status: upstream.status,
                prompt_tokens:     usage?.prompt_tokens     ?? null,
                completion_tokens: usage?.completion_tokens ?? null,
                generation_id:     usage?.id                ?? null,
                cost_usd:          usage?.cost              ?? null,
                task,
                routing_version: ROUTING_VERSION,
                requested_model: model,
                resolved_model: usage?.model ?? null,
            });
        } catch (err) {
            console.warn(`chat-stream usage record skipped: ${err}`);
        } finally {
            clearInterval(watchdog);
        }
    })();
    const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime?.waitUntil) runtime.waitUntil(meter);

    return new Response(toClient, {
        status: upstream.status,
        headers: {
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            ...routingHeaders(model, routed),
        },
    });
}

interface StreamUsage {
    prompt_tokens?: number | null;
    completion_tokens?: number | null;
    cost?: number | null;
    id?: string | null;
    /// The model that actually served, from the chunk's own `model` field —
    /// see `BufferedChat.model`.
    model?: string | null;
    // OpenRouter/Anthropic report cache activity here: `cached_tokens` is the
    // portion of the prompt served from cache (a hit), so a value > 0 on the
    // 2nd+ turn confirms prompt caching is working.
    prompt_tokens_details?: { cached_tokens?: number | null } | null;
}

// Drain a teed SSE stream and pull out the generation id + final usage chunk.
// Tolerant of partial lines across reads, keepalive comments, and malformed
// JSON — anything it can't parse is skipped rather than thrown.
async function readStreamUsage(
    stream: ReadableStream<Uint8Array>,
    onActivity?: () => void,
): Promise<StreamUsage | null> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let usage: StreamUsage | null = null;
    let id: string | null = null;
    let servedModel: string | null = null;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            onActivity?.();
            buf += decoder.decode(value, { stream: true });
            let nl: number;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (data === "[DONE]") continue;
                try {
                    const obj = JSON.parse(data);
                    if (typeof obj?.id === "string") id = obj.id;
                    if (typeof obj?.model === "string") servedModel = obj.model;
                    if (obj?.usage) usage = obj.usage as StreamUsage;
                } catch { /* keepalive / split chunk — ignore */ }
            }
        }
    } finally {
        reader.releaseLock();
    }
    if (usage) return { ...usage, id, model: servedModel };
    return id || servedModel ? { id, model: servedModel } : null;
}

interface BufferedChat {
    content: string;
    usage: StreamUsage | null;
    id: string | null;
    /// The model OpenRouter actually served, from the chunk's own `model`
    /// field — distinct from the `model` this function's caller requested:
    /// the `models` fallback chain can serve a different one on the
    /// requested model's failure, and until now nothing recorded which.
    model: string | null;
    finishReason: string | null;
    error: string | null;
}

// Drain an SSE chat stream into a complete assembled reply: concatenated
// `delta.content`, plus the id, finish_reason, terminal usage, and any upstream
// error chunk. Same tolerant line parsing as readStreamUsage — unparsable lines
// (keepalives, split chunks) are skipped, never thrown.
async function readBufferedChat(
    stream: ReadableStream<Uint8Array>,
    onActivity?: () => void,
): Promise<BufferedChat> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let content = "";
    let usage: StreamUsage | null = null;
    let id: string | null = null;
    let servedModel: string | null = null;
    let finishReason: string | null = null;
    let error: string | null = null;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            onActivity?.();
            buf += decoder.decode(value, { stream: true });
            let nl: number;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (data === "[DONE]") continue;
                try {
                    const obj = JSON.parse(data);
                    if (typeof obj?.id === "string") id = obj.id;
                    if (typeof obj?.model === "string") servedModel = obj.model;
                    if (obj?.usage) usage = obj.usage as StreamUsage;
                    if (obj?.error) {
                        error = typeof obj.error?.message === "string" ? obj.error.message : JSON.stringify(obj.error);
                    }
                    const choice = obj?.choices?.[0];
                    if (typeof choice?.delta?.content === "string") content += choice.delta.content;
                    if (typeof choice?.finish_reason === "string") finishReason = choice.finish_reason;
                } catch { /* keepalive / split chunk — ignore */ }
            }
        }
    } finally {
        reader.releaseLock();
    }
    return { content, usage: usage ? { ...usage, id } : null, id, model: servedModel, finishReason, error };
}

