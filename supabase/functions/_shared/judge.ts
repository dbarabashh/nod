import { isObject, json } from "./http.ts";
import { recordUsage } from "./usage.ts";

// Typed judgments from TypeSafe's System One API: the client sends the state
// and the questions, the key and the model stay here. A missing key answers
// `judge_unavailable`, which every client treats as "decide it the old way".

const TYPESAFE_API_KEY = Deno.env.get("TYPESAFE_API_KEY");
const TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone";

// Pinned rather than `jev-latest`: the client gates on confidence, and an
// alias moving under it would move every threshold it was tuned against.
const TYPESAFE_MODEL = Deno.env.get("TYPESAFE_MODEL") ?? "jev-1.13.0";

// This sits in front of the first token of a chat answer, and the client
// stops waiting after two seconds. A judgment that is late is worth less than
// the fallback the client already has.
const TIMEOUT_MS = 2_500;
const RETRY_AFTER_MS = 300;

// Jev bills per input token and every question is one. The caps keep a client
// bug, or somebody else's client, from turning this into an open relay.
export const JUDGE_MAX_QUESTIONS = 320;
export const JUDGE_MAX_BYTES = 96_000;

// The live transcript is other people's words. Reading a typed question can
// be switched on without it; this is its own decision on each branch.
const MEETING_CONTENT_ALLOWED = Deno.env.get("TYPESAFE_MEETING_CONTENT") === "true";
const MEETING_PURPOSES = new Set(["recall"]);

// A retry the client has stopped waiting for is billed and read by nobody.
const RETRY_WITHIN_MS = 1_200;

const USD_PER_INPUT_TOKEN = 0.042 / 1_000_000;
const QUESTION_TYPES = new Set(["noul", "choice"]);

export interface JudgeRequest {
    state: string | Record<string, unknown> | unknown[];
    questions: Record<string, Record<string, unknown>>;
    purpose?: string;
}

export function judgeRefusal(payload: unknown): { error: string; status: number } | null {
    if (!isObject(payload)) return { error: "judge_payload_invalid", status: 400 };
    const { state, questions } = payload;
    const stateFits = typeof state === "string" || Array.isArray(state) || isObject(state);
    if (!stateFits || !isObject(questions)) return { error: "judge_payload_invalid", status: 400 };
    const entries = Object.values(questions);
    if (entries.length === 0 || entries.length > JUDGE_MAX_QUESTIONS) {
        return { error: "judge_question_count", status: 400 };
    }
    for (const question of entries) {
        if (!isObject(question) || !QUESTION_TYPES.has(String(question.type)) || question.instructions == null) {
            return { error: "judge_question_invalid", status: 400 };
        }
    }
    if (new TextEncoder().encode(JSON.stringify(payload)).length > JUDGE_MAX_BYTES) {
        return { error: "judge_too_large", status: 413 };
    }
    return null;
}

export async function forwardJudge(payload: unknown, userId: string): Promise<Response> {
    if (!TYPESAFE_API_KEY) return json({ error: "judge_unavailable" }, 422);
    const refusal = judgeRefusal(payload);
    if (refusal) return json({ error: refusal.error }, refusal.status);
    const { state, questions, purpose } = payload as JudgeRequest;
    if (MEETING_PURPOSES.has(String(purpose)) && !MEETING_CONTENT_ALLOWED) {
        return json({ error: "judge_unavailable" }, 422);
    }
    const body = JSON.stringify({ state, model: TYPESAFE_MODEL, questions });

    const started = Date.now();
    let { status, parsed } = await ask(body);
    if ((status === 429 || status === 529) && Date.now() - started < RETRY_WITHIN_MS) {
        await new Promise((resolve) => setTimeout(resolve, RETRY_AFTER_MS));
        ({ status, parsed } = await ask(body));
    }
    const inputTokens: number | null = parsed?.usage?.input_tokens ?? null;
    // After the response, not before it: the insert is a round trip the first
    // token of an answer would otherwise wait on.
    const meter = recordUsage({
        user_id: userId,
        kind: "chat",
        model: `typesafe:${parsed?.model ?? TYPESAFE_MODEL}`,
        status,
        prompt_tokens: inputTokens,
        completion_tokens: parsed?.usage?.output_tokens ?? null,
        cost_usd: inputTokens === null ? null : inputTokens * USD_PER_INPUT_TOKEN,
        task: "judge",
    }).catch((error) => console.warn(`judge usage not recorded user=${userId}: ${error}`));
    const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime?.waitUntil) runtime.waitUntil(meter);
    if (status !== 200 || !isObject(parsed?.answers)) {
        console.error(`judge failed user=${userId} status=${status} questions=${Object.keys(questions).length}`);
        return json({ error: "judge_failed" }, 502);
    }
    return json({ model: parsed.model, answers: parsed.answers }, 200);
}

// The body is read inside the deadline: headers arriving is not the answer
// arriving, and an abort that was disarmed at the headers would leave the read
// with no bound at all.
// deno-lint-ignore no-explicit-any
async function ask(body: string): Promise<{ status: number; parsed: any }> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
        const upstream = await fetch(TYPESAFE_URL, {
            method: "POST",
            headers: { "Authorization": `Bearer ${TYPESAFE_API_KEY}`, "Content-Type": "application/json" },
            body,
            signal: controller.signal,
        });
        const parsed = await upstream.json().catch(() => null);
        return { status: parsed === null && upstream.ok ? 504 : upstream.status, parsed };
    } catch {
        return { status: 504, parsed: null };
    } finally {
        clearTimeout(timeout);
    }
}
