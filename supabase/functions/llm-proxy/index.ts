// LLM proxy — server-side gateway for OpenRouter chat + Whisper transcription.
//
// Why this exists (issue #11):
// - Removes the OpenRouter API key from the client binary (it stays in
//   Supabase secrets, only the Edge Function sees it).
// - Authenticates every request with the user's Supabase JWT — gives us a
//   place to enforce per-user quota (issue #17) later.
// - Single network hop for both chat completions and Whisper transcription.
//
// Request shape (POST /functions/v1/llm-proxy):
//   Authorization: Bearer <supabase-access-token>
//   Content-Type:  application/json
//   Body:          { "kind": "chat" | "transcribe", "payload": { …upstream… } }
//
// The `payload` is forwarded verbatim to OpenRouter under the matching
// endpoint, so the upstream contract stays unchanged for the Swift client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");
const SUPABASE_URL       = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY  = Deno.env.get("SUPABASE_ANON_KEY");

const CHAT_TIMEOUT_MS      = 30_000;
const TRANSCRIBE_TIMEOUT_MS = 60_000;

const OPENROUTER_CHAT_URL       = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TRANSCRIBE_URL = "https://openrouter.ai/api/v1/audio/transcriptions";

type Kind = "chat" | "transcribe";

interface ProxyRequest {
    kind: Kind;
    payload: unknown;
}

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
        return json({ error: "Method Not Allowed" }, 405);
    }

    if (!OPENROUTER_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
        console.error("missing env: OPENROUTER_API_KEY / SUPABASE_URL / SUPABASE_ANON_KEY");
        return json({ error: "Server misconfigured" }, 500);
    }

    // JWT check — even though Supabase Edge platform pre-verifies the JWT
    // (verify_jwt default), we re-resolve the user so we can log who's
    // calling and enforce quota in a follow-up.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Unauthenticated" }, 401);

    const token = authHeader.replace(/^Bearer\s+/i, "");
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
        console.warn(`JWT rejected: ${userError?.message ?? "no user"}`);
        return json({ error: "Unauthenticated" }, 401);
    }

    let body: ProxyRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }

    if (!body.kind || body.payload === undefined) {
        return json({ error: "Missing 'kind' or 'payload'" }, 400);
    }

    switch (body.kind) {
        case "chat":
            return forwardToOpenRouter(OPENROUTER_CHAT_URL, body.payload, CHAT_TIMEOUT_MS, user.id, "chat");
        case "transcribe":
            return forwardToOpenRouter(OPENROUTER_TRANSCRIBE_URL, body.payload, TRANSCRIBE_TIMEOUT_MS, user.id, "transcribe");
        default:
            return json({ error: `Unknown kind: ${body.kind}` }, 400);
    }
});

async function forwardToOpenRouter(
    url: string,
    payload: unknown,
    timeoutMs: number,
    userId: string,
    label: string,
): Promise<Response> {
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

        const dt = Date.now() - started;
        console.log(`${label} user=${userId} status=${upstream.status} dt=${dt}ms`);

        // Pipe upstream body straight back — handles JSON, SSE stream, or
        // anything else OpenRouter returns. Preserve content-type so the
        // client can decode correctly.
        return new Response(upstream.body, {
            status: upstream.status,
            headers: {
                "Content-Type": upstream.headers.get("Content-Type") ?? "application/json",
            },
        });
    } catch (error) {
        const dt = Date.now() - started;
        if (error instanceof DOMException && error.name === "AbortError") {
            console.error(`${label} user=${userId} timeout after ${dt}ms`);
            return json({ error: `Upstream timeout (${timeoutMs}ms)` }, 504);
        }
        console.error(`${label} user=${userId} upstream error: ${error}`);
        return json({ error: "Upstream request failed" }, 502);
    } finally {
        clearTimeout(timer);
    }
}

function json(body: unknown, status: number): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}
