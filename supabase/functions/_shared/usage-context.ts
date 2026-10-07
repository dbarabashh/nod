import { isObject } from "./http.ts";

const PURPOSES = ["recap", "speaker_names", "entities", "agent_drafts", "contextual_recall"] as const;
export interface UsageContext {
    purpose?: string;
    meeting_id?: string;
}

export function usageContext(raw: unknown): UsageContext {
    if (!isObject(raw) || !PURPOSES.includes(raw.purpose as typeof PURPOSES[number])) return {};
    const meeting = typeof raw.meeting_id === "string" &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw.meeting_id)
        ? raw.meeting_id : undefined;
    return { purpose: raw.purpose as string, ...(meeting ? { meeting_id: meeting } : {}) };
}

export function usageTokenDetails(raw: unknown) {
    const value = isObject(raw) ? raw : {};
    const completion = isObject(value.completion_tokens_details) ? value.completion_tokens_details : {};
    const prompt = isObject(value.prompt_tokens_details) ? value.prompt_tokens_details : {};
    const count = (n: unknown): number | null => typeof n === "number" && Number.isSafeInteger(n) && n >= 0 && n <= 2147483647 ? n : null;
    return {
        reasoning_tokens: count(completion.reasoning_tokens),
        cached_tokens: count(prompt.cached_tokens),
    };
}
