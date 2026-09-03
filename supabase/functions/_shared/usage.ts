import { adminClient } from "./supabase.ts";
import type { FailoverAttempt } from "./stt-providers.ts";

// One row per billable upstream call. Writing it is always best-effort: a
// logging failure must never fail the user's request, so every caller wraps
// this in its own try/catch.

export interface UsageRow {
    user_id: string;
    kind: "chat" | "transcribe" | "embed" | "speak";
    model: string;
    status: number;
    prompt_tokens?: number | null;
    completion_tokens?: number | null;
    generation_id?: string | null;
    audio_seconds?: number | null;
    cost_usd?: number | null;
    failover?: FailoverAttempt[] | null;
    // Which of the routing-policy categories this call was for
    // (summary/title/utility/chat/stt) — "unknown" for any client built
    // before the `task` field existed.
    task?: string;
    routing_version?: string;
    // `model` above stays whatever the pre-PR-1 callers already put there
    // (for transcribe, the `${provider}:${model}` tag) so nothing that reads
    // it breaks. These two are the honest, separate answer to "what did the
    // client ask for" vs "what actually served" — nullable because not every
    // call site can determine `resolved_model` (e.g. STT providers don't
    // echo one back).
    requested_model?: string | null;
    resolved_model?: string | null;
}

export async function recordUsage(row: UsageRow): Promise<void> {
    // Service role bypasses RLS — required, since the table forbids client
    // inserts. We construct a dedicated client per request rather than reusing
    // the JWT-scoped one above.
    const admin = adminClient();
    const { error } = await admin.from("usage_events").insert(row);
    if (error) {
        console.warn(`usage_events insert failed: ${error.message}`);
    }
}

