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
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireBoolean, requireList, requireString } from "./params.ts";

const LIMIT = 10;
const STATUS_LIMIT = 50;
const FIELDS = "name,completed,due_on,permalink_url,assignee.name,projects.name";

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

interface Task {
    gid?: string;
    name?: string;
    completed?: boolean;
    due_on?: string | null;
    permalink_url?: string;
    assignee?: { name?: string } | null;
    projects?: { name?: string }[];
}

function summarise(task: Task) {
    return {
        id: task.gid,
        title: task.name,
        completed: task.completed === true,
        due: task.due_on ?? null,
        assignee: task.assignee?.name ?? null,
        project: task.projects?.[0]?.name ?? null,
        url: task.permalink_url,
    };
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
            return { searched: true, results: (payload?.data ?? []).map(summarise) };
        } catch (error) {
            if (!(error instanceof ActionError) || error.status !== 502) throw error;

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
                results: (mine?.data ?? []).map(summarise),
            };
        }
    },

    /// Whether tasks Nod filed have since been finished, for the reconciliation
    /// that lets a checkbox in Nod follow work closed in Asana.
    read_tasks: async (connection, params) => {
        const ids = requireList(params, "ids", STATUS_LIMIT);

        // Asana has no batch read for arbitrary ids, and one request each is
        // what it costs. Bounded and concurrent: the caller is a person waiting
        // on a list of checkboxes, and an unbounded list would fan out as wide
        // as the model felt like asking.
        const tasks = await Promise.all(ids.map(async (id) => {
            const payload = await proxy(connection, `api/1.0/tasks/${id}`, null, {
                method: "GET",
                query: { opt_fields: "completed" },
            }) as { data?: Task } | null;
            return { id, closed: payload?.data?.completed === true };
        }));
        return { tasks };
    },

    create_task: async (connection, params) => {
        const title = requireString(params, "title");
        const notes = typeof params.notes === "string" ? params.notes.trim() : "";
        const workspace = await workspaceID(connection);

        const created = await proxy(connection, "api/1.0/tasks", {
            data: {
                name: title,
                workspace,
                assignee: "me",
                ...(notes ? { notes } : {}),
            },
        }) as { data?: Task } | null;

        if (!created?.data?.gid) {
            throw new ActionError("provider_error", "Asana did not return the new task.", 502);
        }
        return { id: created.data.gid, url: created.data.permalink_url };
    },

    update_task: async (connection, params) => {
        const id = requireString(params, "id");
        const completed = requireBoolean(params, "completed");
        await proxy(connection, `api/1.0/tasks/${id}`, { data: { completed } }, { method: "PATCH" });
        return { id, completed };
    },
};
