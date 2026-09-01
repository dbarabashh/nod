// Jira Cloud, over its REST API v3.
//
// The tracker most teams that are not on Linear are on, and it writes as well
// as reads: filing an action item is the thing Nod does with a tracker, and a
// Jira somebody can only search would miss the point of connecting it.
//
// Two things here that no other adapter needs. A 3LO app does not address a
// customer's site directly — every call goes to `api.atlassian.com/ex/jira/
// {cloudId}`, and the cloudId belongs to the connection, so it is resolved once
// per call and cached for the instance. And the old `/rest/api/3/search` was
// shut down in 2025; JQL now lives at `/search/jql`.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireBoolean, requireList, requireString } from "./params.ts";

const SEARCH_LIMIT = 10;
const STATUS_LIMIT = 50;
const FIELDS = "summary,status,assignee,updated";

/// `NOD-31` — a project key and a number.
const KEY = /^[A-Z][A-Z0-9]*-\d+$/i;

/// Which Atlassian site a connection belongs to, per account id.
///
/// One extra round trip the first time and none afterwards. Module scope, so it
/// dies with the instance rather than outliving a revoked grant.
const sites = new Map<string, string>();

async function cloudID(connection: Connection): Promise<string> {
    const cached = sites.get(connection.id);
    if (cached) return cached;

    const payload = await proxy(connection, "https://api.atlassian.com/oauth/token/accessible-resources", null, {
        method: "GET",
    }) as { id?: string }[] | null;

    const id = payload?.[0]?.id;
    if (!id) {
        throw new ActionError(
            "not_connected",
            "This Jira connection does not reach a site any more. Ask the user to reconnect it.",
            409,
        );
    }
    sites.set(connection.id, id);
    return id;
}

/// One Jira request. `path` is relative to the site's REST root.
async function api(
    connection: Connection,
    path: string,
    body: unknown,
    options: { method?: "GET" | "POST"; query?: Record<string, string | undefined> } = {},
): Promise<unknown> {
    const site = await cloudID(connection);
    return await proxy(
        connection,
        `https://api.atlassian.com/ex/jira/${site}/rest/api/3/${path}`,
        body,
        { method: options.method ?? "GET", query: options.query },
    );
}

function issueKey(raw: string): string {
    const key = raw.toUpperCase();
    if (!KEY.test(key)) {
        throw new ActionError("invalid_params", `"${key}" is not a Jira issue key.`);
    }
    return key;
}

function requireKey(params: Record<string, unknown>, name: string): string {
    return issueKey(requireString(params, name));
}

interface Issue {
    key?: string;
    fields?: {
        summary?: string;
        updated?: string;
        status?: { name?: string; statusCategory?: { key?: string } };
        assignee?: { displayName?: string } | null;
    };
}

function summarise(issue: Issue) {
    return {
        key: issue.key,
        title: issue.fields?.summary,
        status: issue.fields?.status?.name,
        assignee: issue.fields?.assignee?.displayName ?? null,
        updated: issue.fields?.updated,
    };
}

/// Jira renders descriptions as Atlassian Document Format, not text or
/// markdown. This is the minimum shape it accepts for a plain paragraph.
function document(text: string) {
    return {
        type: "doc",
        version: 1,
        content: [{ type: "paragraph", content: [{ type: "text", text }] }],
    };
}

/// Escapes a JQL string literal. A summary carrying a quote would otherwise end
/// the clause and change what the query asks.
function quoted(value: string): string {
    return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export const JIRA_ACTIONS: ActionHandlers = {
    search_issues: async (connection, params) => {
        const query = requireString(params, "query");
        const payload = await api(connection, "search/jql", null, {
            query: {
                jql: `text ~ ${quoted(query)} ORDER BY updated DESC`,
                maxResults: String(SEARCH_LIMIT),
                fields: FIELDS,
            },
        }) as { issues?: Issue[] } | null;

        return { results: (payload?.issues ?? []).map(summarise) };
    },

    /// Whether issues Nod filed have since been finished, for the reconciliation
    /// that lets a checkbox in Nod follow work closed in Jira.
    ///
    /// Answers only `closed`. Jira workflows are per-project and unbounded, so a
    /// status name would be a string Nod renders and cannot act on;
    /// `statusCategory` is Jira's own three-way vocabulary and the only part
    /// that means the same thing in every project.
    read_issues: async (connection, params) => {
        const keys = requireList(params, "keys", STATUS_LIMIT).map(issueKey);

        const payload = await api(connection, "search/jql", null, {
            query: {
                jql: `key in (${keys.join(",")})`,
                maxResults: String(keys.length),
                fields: "status",
            },
        }) as { issues?: Issue[] } | null;

        return {
            tasks: (payload?.issues ?? []).map((issue) => ({
                key: issue.key,
                closed: issue.fields?.status?.statusCategory?.key === "done",
            })),
        };
    },

    create_issue: async (connection, params) => {
        const project = requireString(params, "project").toUpperCase();
        const title = requireString(params, "title");
        const description = typeof params.description === "string" ? params.description.trim() : "";

        const created = await api(connection, "issue", {
            fields: {
                project: { key: project },
                summary: title,
                // "Task" rather than the project's default: Jira has no way to
                // ask for the default, and every project template ships a Task.
                issuetype: { name: "Task" },
                ...(description ? { description: document(description) } : {}),
            },
        }, { method: "POST" }) as { key?: string } | null;

        if (!created?.key) {
            throw new ActionError("provider_error", "Jira did not return the new issue.", 502);
        }
        return { key: created.key };
    },

    /// Moves an issue between finished and not, so ticking a filed action item
    /// in Nod closes the ticket rather than only hiding it here.
    ///
    /// Through transitions, because Jira has no settable "closed": the workflow
    /// decides which moves exist, and the same word is spelled "Done", "Closed"
    /// or "Complete" depending on the project. This picks by `statusCategory`,
    /// which is Jira's own vocabulary rather than the team's.
    update_issue: async (connection, params) => {
        const key = requireKey(params, "key");
        const closed = requireBoolean(params, "closed");

        const payload = await api(connection, `issue/${key}/transitions`, null) as {
            transitions?: { id?: string; to?: { statusCategory?: { key?: string } } }[];
        } | null;

        const wanted = closed ? "done" : "new";
        const transition = (payload?.transitions ?? [])
            .find((move) => move.to?.statusCategory?.key === wanted)
            ?? (closed ? undefined : (payload?.transitions ?? [])
                .find((move) => move.to?.statusCategory?.key === "indeterminate"));

        if (!transition?.id) {
            throw new ActionError(
                "provider_error",
                `${key}'s workflow has no move to ${closed ? "done" : "open"} from where it is.`,
                409,
            );
        }

        await api(connection, `issue/${key}/transitions`, { transition: { id: transition.id } }, { method: "POST" });
        return { key, closed };
    },
};
