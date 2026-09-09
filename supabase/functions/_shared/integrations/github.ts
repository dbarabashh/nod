// GitHub, over its REST API.
//
// Reads, and the three writes a meeting actually produces: file an issue,
// comment on one, close or reopen one. Every write stops at the desktop's
// approval card — the same catalogue flag that keeps the reads free to run in
// the live meeting lookup keeps the writes out of it entirely.
//
// Every result is trimmed to what a model needs to answer or to cite, and
// nothing more. Tool *results* — not tool definitions — are where an agent loop
// spends its tokens: definitions are sent once into a cached prefix, while every
// result is fresh input on every subsequent turn.
import { ActionError, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireBoolean, requireString } from "./params.ts";

const SEARCH_LIMIT = 10;
const REPO_LIMIT = 30;
const COMMENT_LIMIT = 3;

/// `owner/repo#123`, which is how a person writes one and how GitHub prints it.
/// The API has no lookup by that string, so every read has to take it apart.
const REFERENCE = /^([\w.-]+)\/([\w.-]+)#(\d+)$/;

/// `owner/repo`, as `list_repositories` returns it. A segment of bare dots is
/// refused separately: `../user` matches the character class and would be
/// normalised by the URL join into a request at an endpoint this adapter never
/// meant to address.
const REPOSITORY = /^[\w.-]+\/[\w.-]+$/;

function dotSegment(name: string): boolean {
    return name.split("/").some((segment) => /^\.+$/.test(segment));
}

function issuePath(params: Record<string, unknown>): { path: string; reference: string } {
    const reference = requireString(params, "reference");
    const parts = REFERENCE.exec(reference);
    if (!parts || dotSegment(`${parts[1]}/${parts[2]}`)) {
        throw new ActionError(
            "invalid_params",
            `"${reference}" is not a GitHub reference. Use owner/repo#123.`,
        );
    }
    const [, owner, repo, number] = parts;
    return { path: `repos/${owner}/${repo}/issues/${number}`, reference };
}

interface Issue {
    number?: number;
    title?: string;
    state?: string;
    html_url?: string;
    updated_at?: string;
    body?: string | null;
    draft?: boolean;
    user?: { login?: string };
    pull_request?: unknown;
    repository_url?: string;
}

/// `https://api.github.com/repos/owner/name` → `owner/name`. Search results
/// carry the repository only as that URL, and a bare issue number is not
/// something anybody can look up.
function repositoryName(url: string | undefined): string | undefined {
    const parts = url?.split("/repos/")[1];
    return parts && parts.split("/").length === 2 ? parts : undefined;
}

/// Issues and pull requests are one type to GitHub, and the distinction is the
/// presence of `pull_request`. Saying which it is matters: "the fix is in
/// AUTH-2" reads very differently for an open issue and a merged PR.
function kindOf(issue: Issue): string {
    return issue.pull_request ? "pull_request" : "issue";
}

export const GITHUB_ACTIONS: ActionHandlers = {
    /// What the account can see matching a query, issues and pull requests
    /// alike.
    ///
    /// GitHub's search syntax is passed through rather than wrapped: `repo:`,
    /// `is:open`, `author:` are the things somebody actually says out loud
    /// ("any open PRs on the api repo?"), and re-inventing them behind our own
    /// parameters would lose exactly the queries that make this useful.
    search_issues: async (connection, params) => {
        const query = requireString(params, "query");
        const payload = await proxy(connection, "search/issues", null, {
            method: "GET",
            query: { q: query, per_page: String(SEARCH_LIMIT), sort: "updated" },
        }) as { items?: Issue[]; total_count?: number } | null;

        const items = payload?.items ?? [];
        return {
            total: payload?.total_count ?? items.length,
            results: items.map((issue) => ({
                reference: repositoryName(issue.repository_url) && issue.number
                    ? `${repositoryName(issue.repository_url)}#${issue.number}`
                    : undefined,
                kind: kindOf(issue),
                title: issue.title,
                state: issue.state,
                author: issue.user?.login,
                updated: issue.updated_at,
                url: issue.html_url,
            })),
        };
    },

    /// One issue or pull request in full, with the tail of its discussion.
    ///
    /// The last few comments rather than all of them: the question this answers
    /// is almost always "where did this get to", and the answer is at the end. A
    /// hundred-comment thread would also be the single largest thing this
    /// adapter could put into a turn.
    read_issue: async (connection, params) => {
        const { path, reference } = issuePath(params);

        // Both addressed by the reference alone, so neither waits on the other.
        const [issue, comments] = await Promise.all([
            proxy(connection, path, null, { method: "GET" }) as Promise<Issue | null>,
            proxy(connection, `${path}/comments`, null, {
                method: "GET",
                query: { per_page: String(COMMENT_LIMIT), sort: "created", direction: "desc" },
            }).catch(() => null) as Promise<{ user?: { login?: string }; body?: string; created_at?: string }[] | null>,
        ]);
        if (!issue?.number) {
            throw new ActionError("not_found", `${reference} is not visible to this account.`, 404);
        }

        return {
            reference,
            kind: kindOf(issue),
            title: issue.title,
            state: issue.state,
            author: issue.user?.login,
            updated: issue.updated_at,
            url: issue.html_url,
            body: issue.body ?? "",
            // Oldest-first, because the model reads them as a conversation even
            // though GitHub hands them back newest-first.
            latest_comments: (comments ?? []).reverse().map((comment) => ({
                author: comment.user?.login,
                at: comment.created_at,
                text: comment.body ?? "",
            })),
        };
    },

    /// The repositories this account works in, most recently touched first.
    ///
    /// What `search_issues` needs before it can narrow: somebody says "the api
    /// repo" and the model has to turn that into `repo:acme/api-server`.
    list_repositories: async (connection) => {
        const payload = await proxy(connection, "user/repos", null, {
            method: "GET",
            query: { per_page: String(REPO_LIMIT), sort: "updated", affiliation: "owner,collaborator,organization_member" },
        }) as { full_name?: string; private?: boolean; description?: string | null; updated_at?: string }[] | null;

        return {
            repositories: (payload ?? []).map((repo) => ({
                name: repo.full_name,
                private: repo.private,
                description: repo.description ?? "",
                updated: repo.updated_at,
            })),
        };
    },

    /// Files one issue, in the meeting's own words.
    create_issue: async (connection, params) => {
        const repository = requireString(params, "repository");
        if (!REPOSITORY.test(repository) || dotSegment(repository)) {
            throw new ActionError("invalid_params", `"${repository}" is not owner/repo.`);
        }
        const title = requireString(params, "title");
        const body = typeof params.body === "string" ? params.body : undefined;

        const created = await proxy(connection, `repos/${repository}/issues`, {
            title,
            ...(body ? { body } : {}),
        }) as Issue | null;
        if (!created?.number) {
            throw new ActionError("provider_error", "GitHub did not return the created issue.", 502);
        }
        return { reference: `${repository}#${created.number}`, title: created.title, url: created.html_url };
    },

    /// Adds one comment to an issue or pull request.
    comment_issue: async (connection, params) => {
        const { path, reference } = issuePath(params);
        const body = requireString(params, "body");

        const comment = await proxy(connection, `${path}/comments`, { body }) as
            { id?: number; html_url?: string } | null;
        if (!comment?.id) {
            throw new ActionError("provider_error", "GitHub did not return the comment.", 502);
        }
        return { reference, url: comment.html_url };
    },

    /// Closes or reopens one issue. State is the whole surface on purpose —
    /// titles, labels and assignees belong to the people working the tracker,
    /// while "close it, that shipped" is a sentence a meeting actually says.
    update_issue: async (connection, params) => {
        const { path, reference } = issuePath(params);
        const closed = requireBoolean(params, "closed");

        const updated = await proxy(connection, path, {
            state: closed ? "closed" : "open",
        }, { method: "PATCH" }) as Issue | null;
        if (!updated?.number) {
            throw new ActionError("provider_error", "GitHub did not return the updated issue.", 502);
        }
        // Issues and pull requests share the endpoint, so the caller learns
        // which one it just closed.
        return { reference, kind: kindOf(updated), state: updated.state, url: updated.html_url };
    },
};
