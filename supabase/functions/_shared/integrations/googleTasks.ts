// Google Tasks, over the Tasks API v1.
//
// Reads and writes the person's default list and nothing else: it is the one
// every account has, the one the Today card means by "make this a task", and
// asking which list would be a question with one answer for almost everyone.
//
// Answers in the same words as Linear and Jira — `key`, `title`, `url`,
// `closed` — so the desktop's filing, status read and duplicate check read a
// Google task without knowing which product answered.
import { ActionError, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireBoolean, requireList, requireString } from "./params.ts";

const SEARCH_LIMIT = 10;
const STATUS_LIMIT = 50;
const TITLE_LIMIT = 1024;
const NOTES_LIMIT = 8192;

export const TASKS_PATH = "tasks/v1/lists/@default/tasks";
// Where a task lives when Google sends no `webViewLink` for it. Tasks have no
// per-task address outside that field, and the desktop refuses a filing
// result without a url.
export const WEB_URL = "https://tasks.google.com/";
// One page at Google's ceiling, completed tasks included: the duplicate check
// before filing wants to find a commitment that is already done, not file it
// again. Cleared tasks stay out — that is what clearing them meant.
export const LIST_QUERY = {
    showCompleted: "true",
    showHidden: "false",
    maxResults: "100",
};

export interface GoogleTask {
    id?: string;
    title?: string;
    notes?: string;
    status?: string;
    due?: string;
    completed?: string;
    updated?: string;
    deleted?: boolean;
    hidden?: boolean;
    webViewLink?: string;
}

export type IdentifiedTask = GoogleTask & { id: string };

export function hasID(task: GoogleTask | null | undefined): task is IdentifiedTask {
    return typeof task?.id === "string" && task.id.length > 0;
}

export function taskPath(id: string): string {
    return `${TASKS_PATH}/${encodeURIComponent(id)}`;
}

export function summarise(task: IdentifiedTask) {
    return {
        key: task.id,
        title: task.title?.trim() || "(no title)",
        url: task.webViewLink ?? WEB_URL,
        closed: task.status === "completed",
        due: task.due ? task.due.slice(0, 10) : null,
        updated: task.updated ?? null,
    };
}

/// How many of the query's words a task's title or notes carry; zero is no
/// match. By words rather than the whole phrase because the desktop asks with
/// the sentence the person said, and a task filed as "Send deck to Alina"
/// never contains "I'll send the deck over to Alina tomorrow".
export function matchScore(task: GoogleTask, query: string): number {
    const words = queryWords(query);
    if (words.length === 0) return 0;
    const text = comparable(`${task.title ?? ""} ${task.notes ?? ""}`);
    return words.filter((word) => text.includes(word)).length;
}

// Words that say nothing about which task is meant, in the two languages Nod
// speaks; scoring them would rank "review the budget over lunch" above a task
// that shares one real word with the question.
const STOPWORDS = new Set([
    "the", "and", "for", "with", "from", "that", "this", "over", "into", "about", "will", "have", "has",
    "are", "was", "were", "you", "your", "our", "them", "they", "then", "than", "not", "but", "can",
    "please", "tomorrow", "today", "next", "week", "also", "just",
    "про", "для", "або", "але", "щоб", "який", "яка", "яке", "які", "цей", "ця", "це", "ці", "той", "та",
    "теж", "вже", "ще", "коли", "після", "перед", "треба", "потрібно", "завтра", "сьогодні",
]);

/// Lowercased, composed, and with every apostrophe form dropped: a Ukrainian
/// keyboard types U+02BC where a pasted title carries U+0027, and Unicode
/// counts one as a letter and not the other.
function comparable(text: string): string {
    return text.normalize("NFC").replace(/['\u2019\u02BC]/gu, "").toLowerCase();
}

function queryWords(query: string): string[] {
    const words = comparable(query)
        .split(/[^\p{L}\p{N}]+/u)
        .filter((word) => word.length >= 3 && !STOPWORDS.has(word));
    if (words.length > 0) return [...new Set(words)];
    const whole = comparable(query).trim();
    return whole ? [whole] : [];
}

function bounded(value: string, key: string, limit: number, what = `\`${key}\``): string {
    if (value.length > limit) {
        throw new ActionError("invalid_params", `${what} is longer than Google allows (${limit} characters).`);
    }
    return value;
}

function requireTitle(params: Record<string, unknown>): string {
    return bounded(requireString(params, "title"), "title", TITLE_LIMIT);
}

/// `notes` is what the chat tool calls it and `description` is what the
/// desktop's filing sends every tracker; the same field either way.
export function notesOf(params: Record<string, unknown>): string | undefined {
    const key = params.notes !== undefined && params.notes !== null ? "notes" : "description";
    const raw = params[key];
    if (raw === undefined || raw === null) return undefined;
    if (typeof raw !== "string") {
        throw new ActionError("invalid_params", `\`${key}\` must be a string.`);
    }
    return bounded(raw.trim(), key, NOTES_LIMIT);
}

const RFC3339 = /^(\d{4}-\d{2}-\d{2})(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/i;

/// The calendar date as written, at midnight UTC. Google keeps only the date
/// of a due timestamp and answers in UTC, so a meeting at 01:00 in Kyiv sent
/// as an instant would land on the day before; the day the person named is
/// the day they meant. `null` clears the date, `undefined` leaves it alone.
export function dueOf(params: Record<string, unknown>): string | null | undefined {
    const raw = params.due;
    if (raw === undefined || raw === "") return undefined;
    if (raw === null) return null;
    if (typeof raw !== "string") {
        throw new ActionError("invalid_params", "`due` must be an RFC3339 timestamp or a YYYY-MM-DD date.");
    }
    const match = RFC3339.exec(raw.trim());
    // Checked against its own round trip: `Date` rolls February 30th into
    // March rather than refusing it.
    const day = match ? new Date(`${match[1]}T00:00:00Z`) : null;
    if (!match || !day || Number.isNaN(day.getTime()) || day.toISOString().slice(0, 10) !== match[1]) {
        throw new ActionError("invalid_params", "`due` must be an RFC3339 timestamp or a YYYY-MM-DD date.");
    }
    return `${match[1]}T00:00:00.000Z`;
}

/// `status` in Google's words, or `closed` in the desktop's; undefined when
/// neither was sent.
export function statusOf(params: Record<string, unknown>): "needsAction" | "completed" | undefined {
    if (params.status !== undefined && params.status !== null) {
        if (params.status === "needsAction" || params.status === "completed") return params.status;
        throw new ActionError("invalid_params", "`status` must be needsAction or completed.");
    }
    if (params.closed !== undefined && params.closed !== null) {
        return requireBoolean(params, "closed") ? "completed" : "needsAction";
    }
    return undefined;
}

export function newTask(params: Record<string, unknown>): GoogleTask {
    const notes = notesOf(params);
    const due = dueOf(params);
    return {
        title: requireTitle(params),
        ...(notes ? { notes } : {}),
        ...(due ? { due } : {}),
    };
}

/// Appended, never replaced — the notes are somebody's writing, and a meeting
/// adds to them.
export function appended(existing: string | undefined, note: string): string {
    const current = existing?.trim();
    return bounded(
        current ? `${current}\n\n---\n\n${note}` : note,
        "note",
        NOTES_LIMIT,
        "The existing notes plus this note",
    );
}

export type TaskPatch = Omit<Partial<GoogleTask>, "completed" | "due"> & {
    completed?: string | null;
    due?: string | null;
};

/// Everything an update may change except an appended note, which needs the
/// task read first. Empty notes are left alone rather than sent: a blank
/// would wipe what the person wrote.
export function taskPatch(params: Record<string, unknown>): TaskPatch {
    const patch: TaskPatch = {};
    if (params.title !== undefined && params.title !== null) patch.title = requireTitle(params);
    const notes = notesOf(params);
    if (notes) patch.notes = notes;
    const due = dueOf(params);
    if (due !== undefined) patch.due = due;
    const status = statusOf(params);
    if (status !== undefined) {
        patch.status = status;
        // Google refuses to reopen a task while its completion stamp stands.
        if (status === "needsAction") patch.completed = null;
    }
    return patch;
}

function noteOf(params: Record<string, unknown>): string {
    return typeof params.note === "string" ? params.note.trim() : "";
}

export const GOOGLE_TASKS_ACTIONS: ActionHandlers = {
    /// Tasks in the default list carrying the words asked for, in the same
    /// shape as the other trackers' searches so the duplicate check before
    /// filing reads it without knowing which product answered.
    ///
    /// Matched here: the Tasks API has no search of its own.
    search_tasks: async (connection, params) => {
        const query = requireString(params, "query");
        const listed = await proxy(connection, TASKS_PATH, null, {
            method: "GET",
            query: LIST_QUERY,
        }) as { items?: GoogleTask[] } | null;

        const live = (listed?.items ?? []).filter(hasID).filter((task) => task.deleted !== true);
        const tasks = orderedForSearch(live, query).slice(0, SEARCH_LIMIT).map((task) => summarise(task));
        return { tasks };
    },

    /// Whether tasks Nod filed have since been finished, for the reconciliation
    /// that lets a checkbox in Nod follow work closed in Google Tasks.
    ///
    /// A task Google no longer has is left out rather than failing the batch:
    /// the read runs every minute over every filed item, and one task the
    /// person deleted would otherwise stop the status of the other forty-nine
    /// for good. Every other refusal still fails the call.
    read_tasks: async (connection, params) => {
        const keys = requireList(params, "keys", STATUS_LIMIT, {
            tooMany: `At most ${STATUS_LIMIT} keys per call.`,
        });

        const tasks = await Promise.all(keys.map(async (key) => {
            try {
                const task = await proxy(connection, taskPath(key), null, { method: "GET" }) as GoogleTask | null;
                if (!hasID(task) || task.deleted === true) return null;
                return {
                    key: task.id,
                    closed: task.status === "completed",
                    title: task.title?.trim() || "(no title)",
                    due: task.due ? task.due.slice(0, 10) : null,
                    completed: task.completed ?? null,
                };
            } catch (error) {
                if (error instanceof ActionError && isGone(error)) return null;
                throw error;
            }
        }));
        return { tasks: tasks.filter((task) => task !== null) };
    },

    create_task: async (connection, params) => {
        const created = await proxy(connection, TASKS_PATH, newTask(params), { method: "POST" }) as
            | GoogleTask
            | null;
        if (!hasID(created)) {
            throw new ActionError("provider_error", "Google did not return the new task.", 502);
        }
        const { key, title, url } = summarise(created);
        return { key, title, url };
    },

    /// Changes one task: its words, its date, or whether it is done. Carries
    /// `closed` as well as `status` so ticking a filed action item in Nod
    /// completes the task, and `note` so a meeting can add to one.
    update_task: async (connection, params) => {
        const key = requireString(params, "key");
        const patch = taskPatch(params);
        const note = noteOf(params);
        if (note) {
            if (patch.notes !== undefined) {
                throw new ActionError("invalid_params", "Pass `notes` to replace the notes or `note` to add to them, not both.");
            }
            const current = await proxy(connection, taskPath(key), null, { method: "GET" }) as GoogleTask | null;
            patch.notes = appended(current?.notes, note);
        }
        if (Object.keys(patch).length === 0) {
            throw new ActionError("invalid_params", "Nothing to update — pass `title`, `notes`, `note`, `due` or `status`.");
        }

        const updated = await proxy(connection, taskPath(key), patch, { method: "PATCH" }) as GoogleTask | null;
        if (!hasID(updated)) {
            throw new ActionError("provider_error", `Google did not update task ${key}.`, 502);
        }
        const { title, url, closed } = summarise(updated);
        return { key: updated.id, title, url, closed };
    },
};

/// Open before done, so a dozen finished copies of a recurring task cannot
/// push the live one past the cap and leave the desktop linking a closed twin.
function rank(task: GoogleTask): number {
    return task.status === "completed" ? 1 : 0;
}

function newer(a: GoogleTask, b: GoogleTask): number {
    return (b.updated ?? "").localeCompare(a.updated ?? "");
}

export function orderedForSearch<T extends GoogleTask>(tasks: T[], query: string): T[] {
    return tasks
        .map((task) => ({ task, score: matchScore(task, query) }))
        .filter(({ score }) => score > 0)
        .sort((a, b) => b.score - a.score || rank(a.task) - rank(b.task) || newer(a.task, b.task))
        .map(({ task }) => task);
}

function isGone(error: ActionError): boolean {
    return error.providerStatus === 404 || error.providerStatus === 410;
}
