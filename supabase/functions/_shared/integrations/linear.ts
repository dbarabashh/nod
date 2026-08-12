// Linear, over its GraphQL API.
//
// Every result here is trimmed to what a model needs to answer or to cite, and
// nothing more. Tool *results* — not tool definitions — are where an agent loop
// actually spends its tokens: definitions are sent once into a cached prefix,
// while every result is fresh input on every subsequent turn.
import { ActionError, type Connection, proxy } from "./nango.ts";
import type { ActionHandlers } from "./registry.ts";

const SEARCH_LIMIT = 10;

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
    search_issues: async (connection, params) => {
        const term = requireString(params, "query");
        const data = await graphql(
            connection,
            `query($term: String!, $first: Int!) {
                searchIssues(term: $term, first: $first) {
                    nodes { identifier title url state { name } assignee { name } }
                }
            }`,
            { term, first: SEARCH_LIMIT },
        );
        const nodes = (data.searchIssues as { nodes?: unknown[] } | undefined)?.nodes ?? [];
        return { issues: nodes };
    },

    create_issue: async (connection, params) => {
        const title = requireString(params, "title");
        const description = typeof params.description === "string" ? params.description : undefined;
        const teamId = await resolveTeamID(connection, params.teamId);

        const data = await graphql(
            connection,
            `mutation($input: IssueCreateInput!) {
                issueCreate(input: $input) {
                    success
                    issue { identifier title url }
                }
            }`,
            { input: { title, description, teamId } },
        );
        const result = data.issueCreate as { success?: boolean; issue?: unknown } | undefined;
        if (!result?.success || !result.issue) {
            throw new ActionError("provider_error", "Linear did not create the issue.", 502);
        }
        return result.issue;
    },
};
