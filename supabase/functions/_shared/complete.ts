import { withProviderFloor } from "./model-policy.ts";
import { recordUsage } from "./usage.ts";
import { usageTokenDetails } from "./usage-context.ts";
import { UpstreamRateLimit, retryAfterSeconds } from "./rate-limit.ts";

// One-shot OpenRouter completion for server-originated calls (the distiller,
// the beat worker). The proxied chat path in `chat.ts` stays separate: it
// forwards a client-built payload, streams, and applies routing policy —
// different job, different shape.

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");
const OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";

// A server job nobody is watching must still end: a hung upstream would
// otherwise hold the worker until the platform kills it.
const TIMEOUT_MS = 90_000;

export interface CompleteRequest {
    model: string;
    system: string;
    user: string;
    userId: string;
    /// The `usage_events.task` label this call is billed under.
    task: string;
    temperature?: number;
    reasoningOff?: boolean;
    meetingId?: string;
    deferRateLimits?: boolean;
}

export async function completeOnce(req: CompleteRequest): Promise<string | null> {
    if (!OPENROUTER_API_KEY) return null;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
        const started = Date.now();
        const upstream = await fetch(OPENROUTER_CHAT_URL, {
            method: "POST",
            headers: {
                "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
                "Content-Type": "application/json",
            },
            body: JSON.stringify(withProviderFloor({
                model: req.model,
                messages: [
                    { role: "system", content: req.system },
                    { role: "user", content: req.user },
                ],
                ...(req.temperature === undefined ? {} : { temperature: req.temperature }),
                ...(req.reasoningOff ? { reasoning: { enabled: false } } : {}),
                usage: { include: true },
            })),
            signal: controller.signal,
        });
        const parsed = await upstream.json().catch(() => null);
        const content: string = parsed?.choices?.[0]?.message?.content ?? "";
        try {
            await recordUsage({
                user_id: req.userId,
                kind: "chat",
                model: req.model,
                status: upstream.status,
                prompt_tokens: parsed?.usage?.prompt_tokens ?? null,
                completion_tokens: parsed?.usage?.completion_tokens ?? null,
                cost_usd: parsed?.usage?.cost ?? null,
                generation_id: parsed?.id ?? null,
                meeting_id: req.meetingId ?? null,
                ...usageTokenDetails(parsed?.usage),
                task: req.task,
                requested_model: req.model,
                resolved_model: parsed?.model ?? null,
            });
        } catch (err) {
            console.warn(`${req.task} usage record skipped: ${err}`);
        }
        console.log(`${req.task} model status=${upstream.status} dt=${Date.now() - started}ms chars=${content.length}`);
        if (upstream.status === 429 && req.deferRateLimits) {
            throw new UpstreamRateLimit(retryAfterSeconds(upstream.headers.get("Retry-After")));
        }
        if (!upstream.ok || content.trim().length === 0) return null;
        return content;
    } catch (err) {
        if (err instanceof UpstreamRateLimit) throw err;
        console.error(`${req.task} model call failed: ${err}`);
        return null;
    } finally {
        clearTimeout(timeout);
    }
}
