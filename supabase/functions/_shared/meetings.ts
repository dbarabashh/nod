// Provider-agnostic meeting data access for external connections.
//
// `connect` (and any future transport adapter — a remote MCP HTTP endpoint, an
// OpenAPI/REST surface) calls these with an already-resolved `userId`. Every
// query runs with the service role BUT is always scoped `.eq("user_id", userId)`,
// which reproduces each table's per-user RLS while letting us page past the
// 1000-row cap. Keeping the data logic here (not inline in one transport) is the
// whole point: adding ChatGPT/Gemini surfaces reuses this, never re-implements it.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const DEFAULT_LIST = 25;
const MAX_LIST = 100;
const MAX_TRANSCRIPT_ROWS = 5000;
const PAGE = 1000;

const MEETING_COLUMNS = "id, title, started_at, ended_at, kind, language, summary";

// The row shape `MEETING_COLUMNS` selects — the single source of truth for
// transports formatting these rows.
export interface Meeting {
    id: string;
    title: string | null;
    started_at: string | null;
    ended_at: string | null;
    kind: string | null;
    language: string | null;
    summary: string | null;
}

export interface ListOptions {
    limit?: number;
    kind?: string;
    before?: string; // ISO timestamp — page older than this `started_at`
}

function clampLimit(n: unknown): number {
    const v = typeof n === "number" && Number.isFinite(n) ? Math.floor(n) : DEFAULT_LIST;
    return Math.max(1, Math.min(MAX_LIST, v));
}

export async function listMeetings(admin: SupabaseClient, userId: string, opts: ListOptions = {}) {
    let q = admin
        .from("meetings")
        .select(MEETING_COLUMNS)
        .eq("user_id", userId)
        .is("deleted_at", null)
        .order("started_at", { ascending: false })
        .limit(clampLimit(opts.limit));

    if (opts.kind) q = q.eq("kind", opts.kind);
    if (opts.before) q = q.lt("started_at", opts.before);

    const { data, error } = await q;
    if (error) throw new Error(`list meetings: ${error.message}`);
    return data ?? [];
}

export async function getMeeting(admin: SupabaseClient, userId: string, id: string) {
    const { data, error } = await admin
        .from("meetings")
        .select(`${MEETING_COLUMNS}, recap_json`)
        .eq("user_id", userId)
        .eq("id", id)
        .is("deleted_at", null)
        .maybeSingle();
    if (error) throw new Error(`get meeting: ${error.message}`);
    return data;
}

export async function searchMeetings(admin: SupabaseClient, userId: string, query: string, limit?: number) {
    const term = (query ?? "").trim();
    if (!term) return [];
    // Quote the value so reserved `.or()` chars in the query (comma, parens) don't
    // break the filter; escape ilike wildcards and embedded quotes within it.
    const escaped = term.replace(/[%_]/g, (m) => `\\${m}`).replace(/"/g, '\\"');
    const pattern = `"%${escaped}%"`;
    const { data, error } = await admin
        .from("meetings")
        .select(MEETING_COLUMNS)
        .eq("user_id", userId)
        .is("deleted_at", null)
        .or(`title.ilike.${pattern},summary.ilike.${pattern}`)
        .order("started_at", { ascending: false })
        .limit(clampLimit(limit));
    if (error) throw new Error(`search meetings: ${error.message}`);
    return data ?? [];
}

export async function getTranscript(admin: SupabaseClient, userId: string, meetingId: string) {
    // Confirm ownership before reading transcript rows — the meeting query is the
    // RLS-equivalent gate; the transcript table is then safe to page by id.
    const meeting = await getMeeting(admin, userId, meetingId);
    if (!meeting) return null;

    const rows: Array<{ source: string; text: string; idx: number; ts: string }> = [];
    let truncated = false;
    for (let from = 0; from < MAX_TRANSCRIPT_ROWS; from += PAGE) {
        const to = Math.min(from + PAGE, MAX_TRANSCRIPT_ROWS) - 1;
        const { data, error } = await admin
            .from("meeting_transcripts")
            .select("source, text, idx, ts")
            .eq("user_id", userId)
            .eq("meeting_id", meetingId)
            .order("idx", { ascending: true })
            .range(from, to);
        if (error) throw new Error(`get transcript: ${error.message}`);
        const page = (data ?? []) as typeof rows;
        rows.push(...page);
        if (page.length < PAGE) break;
        if (rows.length >= MAX_TRANSCRIPT_ROWS) {
            truncated = true;
            break;
        }
    }
    return { meeting, lines: rows, truncated };
}
