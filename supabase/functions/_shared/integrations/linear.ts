// Linear, over its GraphQL API.
//
// Every result here is trimmed to what a model needs to answer or to cite, and
// nothing more. Tool *results* — not tool definitions — are where an agent loop
// actually spends its tokens: definitions are sent once into a cached prefix,
// while every result is fresh input on every subsequent turn.
import { ActionError, type Connection, proxy } from "./nango.ts";
import type { ActionHandlers } from "./registry.ts";

const SEARCH_LIMIT = 10;
const STATUS_LIMIT = 50;

/// `NOD-31` — a team key and a number, which is all Linear's API can filter on.
/// There is no lookup by identifier, so every read has to be taken apart.
const IDENTIFIER = /^([A-Za-z][A-Za-z0-9]*)-(\d+)$/;

async function graphql(
    connection: Connection,
    query: string,
    variables: Record<string, unknown>,
): Promise<Record<string, unknown>> {
    const payload = await proxy(connection, "graphql", { query, variables }) as {
        data?: Record<string, unknown>;
        errors?: { message?: string }[];
    } | null;

    if (payload?.errors?.length) {
        const detail = payload.errors[0]?.message ?? "unknown error";
        throw new ActionError("provider_error", `Linear rejected the request: ${detail}`, 502);
    }
    if (!payload?.data) {
        throw new ActionError("provider_error", "Linear returned no data.", 502);
    }
    return payload.data;
}

/// The issue behind a `NOD-31`, with what an update needs to know about it.
async function resolveIssue(connection: Connection, key: string) {
    const parts = IDENTIFIER.exec(key);
    if (!parts) {
        throw new ActionError("invalid_params", `"${key}" is not a Linear identifier.`);
    }
    const data = await graphql(
        connection,
        `query($team: String!, $number: Float!) {
            issues(filter: { team: { key: { eq: $team } }, number: { eq: $number } }, first: 1) {
                nodes { id description state { type } team { id } }
            }
        }`,
        { team: parts[1].toUpperCase(), number: Number(parts[2]) },
    );
    const issue = (data.issues as {
        nodes?: { id: string; description?: string; state?: { type?: string }; team?: { id?: string } }[];
    } | undefined)?.nodes?.[0];
    if (!issue?.team?.id) {
        throw new ActionError("not_found", `${key} no longer exists in Linear.`, 404);
    }
    return {
        id: issue.id,
        teamID: issue.team.id,
        description: issue.description ?? "",
        closed: issue.state?.type === "completed" || issue.state?.type === "canceled",
    };
}

/// A team's own column of the given kind. Which one an issue lands in is the
/// workspace's business — Nod knows "finished" and "not finished" and nothing
/// finer, so it asks for a type and takes whatever that team calls it.
async function stateOfType(connection: Connection, teamID: string, type: string): Promise<string> {
    const data = await graphql(
        connection,
        `query($team: ID!, $type: String!) {
            workflowStates(
                filter: { team: { id: { eq: $team } }, type: { eq: $type } }
                first: 1
            ) { nodes { id } }
        }`,
        { team: teamID, type },
    );
    const state = (data.workflowStates as { nodes?: { id: string }[] } | undefined)?.nodes?.[0];
    if (!state) {
        throw new ActionError("no_state", `This Linear team has no "${type}" column.`);
    }
    return state.id;
}

function requireBoolean(params: Record<string, unknown>, key: string): boolean {
    const value = params[key];
    if (typeof value === "boolean") return value;
    if (value === "true") return true;
    if (value === "false") return false;
    throw new ActionError("invalid_params", `\`${key}\` must be true or false.`);
}

function requireString(params: Record<string, unknown>, key: string): string {
    const value = params[key];
    if (typeof value !== "string" || value.trim().length === 0) {
        throw new ActionError("invalid_params", `\`${key}\` is required.`);
    }
    return value.trim();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/// Turns whatever the model offered into a team UUID.
///
/// A model knows a team the way a person does — as "NOD", or as "Nod" — because
/// that is what Linear shows. It has no way to learn a UUID, so it passes the
/// key and Linear answers "teamId must be a UUID". Resolving here is the
/// difference between a tool that works and one that is technically correct.
async function resolveTeamID(connection: Connection, hint: unknown): Promise<string> {
    const wanted = typeof hint === "string" ? hint.trim() : "";
    if (UUID.test(wanted)) return wanted;

    const data = await graphql(connection, "{ teams(first: 50) { nodes { id key name } } }", {});
    const teams = (data.teams as { nodes?: { id: string; key: string; name: string }[] } | undefined)?.nodes ?? [];
    if (teams.length === 0) {
        throw new ActionError("no_team", "This Linear workspace has no team to file issues in.");
    }

    if (wanted) {
        const match = teams.find((team) =>
            team.key.toLowerCase() === wanted.toLowerCase() ||
            team.name.toLowerCase() === wanted.toLowerCase()
        );
        if (match) return match.id;
        const known = teams.map((team) => team.key).join(", ");
        throw new ActionError("unknown_team", `No Linear team matches "${wanted}". Teams: ${known}.`);
    }

    if (teams.length > 1) {
        const known = teams.map((team) => team.key).join(", ");
        throw new ActionError("team_required", `Ask the user which team, then pass its key. Teams: ${known}.`);
    }
    return teams[0].id;
}

export const LINEAR_ACTIONS: ActionHandlers = {
    /// Whether issues Nod filed have since been finished, for the reconciliation
    /// that lets a checkbox in Nod follow work closed in Linear.
    ///
    /// Answers only `closed`, deliberately: Nod has no workflow of its own to
    /// map "In Review" onto, and a state name it can't act on would be a string
    /// rendered somewhere and meaning nothing. Keys absent from the reply — an
    /// issue deleted, or moved out of reach — are simply not reported, so an
    /// item Nod can no longer see is left as the user last had it.
    read_issues: async (connection, params) => {
        const keys = requireString(params, "keys")
            .split(",")
            .map((key) => key.trim())
            .filter(Boolean);
        if (keys.length === 0) {
            throw new ActionError("invalid_params", "`keys` is required.");
        }
        if (keys.length > STATUS_LIMIT) {
            throw new ActionError("invalid_params", `At most ${STATUS_LIMIT} keys per call.`);
        }

        const or = keys.map((key) => {
            const parts = IDENTIFIER.exec(key);
            if (!parts) {
                throw new ActionError("invalid_params", `"${key}" is not a Linear identifier.`);
            }
            return { team: { key: { eq: parts[1].toUpperCase() } }, number: { eq: Number(parts[2]) } };
        });

        const data = await graphql(
            connection,
            `query($filter: IssueFilter!, $first: Int!) {
                issues(filter: $filter, first: $first) {
                    nodes { identifier state { type } }
                }
            }`,
            { filter: { or }, first: keys.length },
        );
        const nodes = (data.issues as {
            nodes?: { identifier: string; state?: { type?: string } }[];
        } | undefined)?.nodes ?? [];

        // `state.type` rather than `state.name`: the name is whatever the
        // workspace renamed its column to, the type is Linear's own vocabulary.
        return {
            tasks: nodes.map((issue) => ({
                key: issue.identifier,
                closed: issue.state?.type === "completed" || issue.state?.type === "canceled",
            })),
        };
    },

    /// Moves an issue between finished and not, so ticking a filed action item
    /// in Nod closes the ticket rather than only hiding it here.
    ///
    /// Carries `closed` and nothing else. Reopening lands in the team's first
    /// unstarted column, which is a real loss of fidelity — an issue that was
    /// "In Review" comes back as "Todo", because Nod never knew which column it
    /// left. That beats the alternative: with no way to reopen, an item unticked
    /// in Nod would be re-ticked by the next status read, and the checkbox would
    /// argue with the person using it.
    update_issue: async (connection, params) => {
        const key = requireString(params, "key");
        const note = typeof params.note === "string" ? params.note.trim() : "";
        const hasClosed = params.closed !== undefined;
        const closed = hasClosed ? requireBoolean(params, "closed") : false;
        if (!note && !hasClosed) {
            throw new ActionError("invalid_params", "Nothing to update — pass `note`, `closed`, or both.");
        }

        const issue = await resolveIssue(connection, key);
        const input: Record<string, unknown> = {};

        // Appended, never replaced. A ticket description is somebody's writing,
        // possibly a whole spec; a meeting adds to it and does not get to
        // overwrite it. The heading is what makes the addition legible as an
        // addition three weeks later.
        if (note) {
            input.description = issue.description
                ? `${issue.description}\n\n---\n\n${note}`
                : note;
        }
        if (hasClosed && issue.closed !== closed) {
            input.stateId = await stateOfType(connection, issue.teamID, closed ? "completed" : "unstarted");
        }
        if (Object.keys(input).length === 0) return { key, closed: issue.closed };

        const data = await graphql(
            connection,
            `mutation($id: String!, $input: IssueUpdateInput!) {
                issueUpdate(id: $id, input: $input) { success issue { identifier title url } }
            }`,
            { id: issue.id, input },
        );
        const result = data.issueUpdate as {
            success?: boolean;
            issue?: { identifier: string; title: string; url: string };
        } | undefined;
        if (!result?.success || !result.issue) {
            throw new ActionError("provider_error", `Linear did not update ${key}.`, 502);
        }
        // The same three words `create_issue` answers with, so a client that
        // just filed and a client that just updated read the result the same.
        return {
            key: result.issue.identifier,
            title: result.issue.title,
            url: result.issue.url,
            closed: hasClosed ? closed : issue.closed,
        };
    },

    search_issues: async (connection, params) => {
        const term = requireString(params, "query");
        const data = await graphql(
            connection,
            `query($term: String!, $first: Int!) {
                searchIssues(term: $term, first: $first) {
                    nodes { identifier title url state { name type } assignee { name } }
                }
            }`,
            { term, first: SEARCH_LIMIT },
        );
        const nodes = (data.searchIssues as {
            nodes?: {
                identifier: string;
                title: string;
                url: string;
                state?: { name?: string; type?: string };
                assignee?: { name?: string };
            }[];
        } | undefined)?.nodes ?? [];

        // Same `{ key, closed }` core as `create_issue` and `read_issues`, so the
        // duplicate check before filing reads a search result without knowing
        // which product answered. `state` and `assignee` ride along for the
        // model, which is the other reader and wants words, not a boolean.
        return {
            tasks: nodes.map((issue) => ({
                key: issue.identifier,
                title: issue.title,
                url: issue.url,
                closed: issue.state?.type === "completed" || issue.state?.type === "canceled",
                state: issue.state?.name,
                assignee: issue.assignee?.name,
            })),
        };
    },

    /// The workspace's members, so a person Nod knows can be matched to the
    /// account Linear knows.
    ///
    /// Read-only and email-keyed, because the address is the one field both
    /// systems agree on — a display name is whatever somebody typed, and Linear
    /// ids mean nothing outside Linear. Callers that cannot see an address get
    /// no match, which is the correct outcome rather than a guessed one.
    list_users: async (connection) => {
        const data = await graphql(
            connection,
            "{ users(first: 250, filter: { active: { eq: true } }) { nodes { id name email } } }",
            {},
        );
        const nodes = (data.users as { nodes?: { id: string; name: string; email?: string }[] } | undefined)
            ?.nodes ?? [];
        return { users: nodes.filter((user) => user.email) };
    },

    create_issue: async (connection, params) => {
        const title = requireString(params, "title");
        const description = typeof params.description === "string" ? params.description : undefined;
        const teamId = await resolveTeamID(connection, params.teamId);
        // Already a Linear user id by the time it reaches here — resolving a
        // person to their account is the executor's job, and doing it again from
        // a name would be a second place that could name the wrong colleague.
        const assigneeId = typeof params.assigneeId === "string" && params.assigneeId.trim()
            ? params.assigneeId.trim()
            : undefined;

        const data = await graphql(
            connection,
            `mutation($input: IssueCreateInput!) {
                issueCreate(input: $input) {
                    success
                    issue { identifier title url }
                }
            }`,
            { input: { title, description, teamId, assigneeId } },
        );
        const result = data.issueCreate as {
            success?: boolean;
            issue?: { identifier: string; title: string; url: string };
        } | undefined;
        if (!result?.success || !result.issue) {
            throw new ActionError("provider_error", "Linear did not create the issue.", 502);
        }
        // `key`, not `identifier`: what a task action returns is the same three
        // words whichever product answered, so a client can read the result
        // without knowing which one it asked.
        return { key: result.issue.identifier, title: result.issue.title, url: result.issue.url };
    },
};
