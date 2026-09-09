// Asana, over its REST API.
//
// Reads and writes, like the other trackers: filing an action item is the thing
// Nod does with one.
//
// The wrinkle here is that Asana's search is a paid feature. `tasks/search`
// answers `402` on a free workspace, which is not an error the person can act
// on — they did nothing wrong and there is nothing to fix. So a refused search
// falls back to the tasks assigned to them, which every plan allows, and says
// which of the two it did.
//
// Asana's own words are `gid`, `notes` and `completed`; the task contract's
// are `key`, `description` and `closed`. Both are accepted on the way in and
// both are answered on the way out, because the chat tool was written in
// Asana's and the desktop files in the contract's.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { booleanOf, nameOf, requireList, requireString } from "./params.ts";
import { taskReference } from "./taskContract.ts";

const LIMIT = 10;
const STATUS_LIMIT = 50;
const FIELDS = "name,notes,completed,due_on,permalink_url,assignee.name,projects.name";

/// The workspace a connection works in, per account id. Asana scopes almost
/// everything to one and never infers it.
const workspaces = new Map<string, string>();

async function workspaceID(connection: Connection): Promise<string> {
    const cached = workspaces.get(connection.id);
    if (cached) return cached;

    const payload = await proxy(connection, "api/1.0/users/me", null, {
        method: "GET",
        query: { opt_fields: "workspaces.name" },
    }) as { data?: { workspaces?: { gid?: string }[] } } | null;

    const gid = payload?.data?.workspaces?.[0]?.gid;
    if (!gid) {
        throw new ActionError(
            "not_connected",
            "This Asana connection reaches no workspace. Ask the user to reconnect it.",
            409,
        );
    }
    workspaces.set(connection.id, gid);
    return gid;
}

export interface Task {
    gid?: string;
    name?: string;
    notes?: string;
    completed?: boolean;
    due_on?: string | null;
    permalink_url?: string;
    assignee?: { name?: string } | null;
    projects?: { name?: string }[];
}

export type IdentifiedTask = Task & { gid: string };

export function hasID(task: Task | null | undefined): task is IdentifiedTask {
    return typeof task?.gid === "string" && task.gid.length > 0;
}

export function summarise(task: IdentifiedTask) {
    return taskReference({
        key: task.gid,
        id: task.gid,
        title: task.name,
        url: task.permalink_url,
        closed: task.completed === true,
        completed: task.completed === true,
        due: task.due_on ?? null,
        assignee: task.assignee?.name ?? null,
        project: task.projects?.[0]?.name ?? null,
    });
}

export function keyOf(params: Record<string, unknown>): string {
    return requireString(params, nameOf(params, "key", "id"));
}

export function closedOf(params: Record<string, unknown>): boolean | undefined {
    return booleanOf(params, nameOf(params, "closed", "completed"));
}

export function notesOf(params: Record<string, unknown>): string {
    const raw = params[nameOf(params, "description", "notes")];
    return typeof raw === "string" ? raw.trim() : "";
}

/// Appended, never replaced — the notes are somebody's writing, and a meeting
/// adds to them.
export function appended(existing: string | undefined, note: string): string {
    const current = existing?.trim();
    return current ? `${current}\n\n---\n\n${note}` : note;
}

/// Asana's `402` on `tasks/search` from a free workspace — the one refusal the
/// fallback is for. Anything else, a revoked grant included, is still an error.
export function isSearchPaywalled(error: unknown): boolean {
    return error instanceof ActionError && error.providerStatus === 402;
}

function identified(tasks: Task[] | undefined): IdentifiedTask[] {
    return (tasks ?? []).filter(hasID);
}

async function readTask(connection: Connection, gid: string): Promise<IdentifiedTask> {
    const payload = await proxy(connection, `api/1.0/tasks/${encodeURIComponent(gid)}`, null, {
        method: "GET",
        query: { opt_fields: FIELDS },
    }).catch((error) => {
        if (error instanceof ActionError && error.providerStatus === 404) return null;
        throw error;
    }) as { data?: Task } | null;
    if (!hasID(payload?.data)) {
        throw new ActionError("not_found", `Task ${gid} is not visible to this account.`, 404);
    }
    return payload.data;
}

export const ASANA_ACTIONS: ActionHandlers = {
    /// Tasks matching a phrase, or — where the plan forbids searching — the
    /// person's own open tasks.
    ///
    /// The fallback is narrower than the question asked, so the answer says so:
    /// a model told `searched: false` can tell the user it looked at their own
    /// list rather than everything, instead of reporting an absence it never
    /// checked for.
    search_tasks: async (connection, params) => {
        const query = requireString(params, "query");
        const workspace = await workspaceID(connection);

        try {
            const payload = await proxy(connection, `api/1.0/workspaces/${workspace}/tasks/search`, null, {
                method: "GET",
                query: { text: query, limit: String(LIMIT), opt_fields: FIELDS },
            }) as { data?: Task[] } | null;
            return { searched: true, tasks: identified(payload?.data).map(summarise) };
        } catch (error) {
            if (!isSearchPaywalled(error)) throw error;

            const mine = await proxy(connection, "api/1.0/tasks", null, {
                method: "GET",
                query: {
                    assignee: "me",
                    workspace,
                    completed_since: "now",
                    limit: String(LIMIT),
                    opt_fields: FIELDS,
                },
            }) as { data?: Task[] } | null;

            return {
                searched: false,
                note: "Asana's search needs a paid workspace, so these are the user's own open tasks rather than a search.",
                tasks: identified(mine?.data).map(summarise),
            };
        }
    },

    /// Whether tasks Nod filed have since been finished, for the reconciliation
    /// that lets a checkbox in Nod follow work closed in Asana.
    read_tasks: async (connection, params) => {
        const keys = requireList(params, nameOf(params, "keys", "ids"), STATUS_LIMIT);

        // Asana has no batch read for arbitrary ids, and one request each is
        // what it costs. Bounded and concurrent: the caller is a person waiting
        // on a list of checkboxes, and an unbounded list would fan out as wide
        // as the model felt like asking.
        const tasks = await Promise.all(keys.map(async (key) => {
            const payload = await proxy(connection, `api/1.0/tasks/${encodeURIComponent(key)}`, null, {
                method: "GET",
                query: { opt_fields: "completed" },
            }) as { data?: Task } | null;
            return { key, id: key, closed: payload?.data?.completed === true };
        }));
        return { tasks };
    },

    create_task: async (connection, params) => {
        const title = requireString(params, "title");
        const notes = notesOf(params);
        const workspace = await workspaceID(connection);

        const created = await proxy(connection, "api/1.0/tasks", {
            data: {
                name: title,
                workspace,
                assignee: "me",
                ...(notes ? { notes } : {}),
            },
        }) as { data?: Task } | null;

        if (!hasID(created?.data)) {
            throw new ActionError("provider_error", "Asana did not return the new task.", 502);
        }
        const { key, id, url } = summarise(created.data);
        return { key, id, title, url };
    },

    /// Adds a note, completes or reopens a task, or both.
    ///
    /// A note is appended to the task's own notes rather than posted as a
    /// story: a story in Asana is a comment somebody has to click into, and the
    /// notes are what the task says.
    update_task: async (connection, params) => {
        const key = keyOf(params);
        const note = typeof params.note === "string" ? params.note.trim() : "";
        const closed = closedOf(params);
        if (!note && closed === undefined) {
            throw new ActionError("invalid_params", "Nothing to update — pass `note`, `closed`, or both.");
        }

        const data: Record<string, unknown> = {};
        if (closed !== undefined) data.completed = closed;
        if (note) {
            const current = await readTask(connection, key);
            data.notes = appended(current.notes, note);
        }

        const updated = await proxy(connection, `api/1.0/tasks/${encodeURIComponent(key)}`, { data }, {
            method: "PUT",
            query: { opt_fields: FIELDS },
        }) as { data?: Task } | null;
        if (!hasID(updated?.data)) {
            throw new ActionError("provider_error", `Asana did not update task ${key}.`, 502);
        }
        const { id, title, url, closed: nowClosed } = summarise(updated.data);
        return { key, id, title, url, closed: nowClosed, completed: nowClosed };
    },
};
