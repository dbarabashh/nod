// Notion, over its REST API.
//
// Read-only. What a meeting needs from Notion is "what did we already write
// about this", and the answer to that is never a new page — writing one would
// be Nod filing prose nobody reviewed into a company's wiki.
//
// Every result is trimmed to what a model needs to answer or to cite, and
// nothing more. Tool *results* — not tool definitions — are where an agent loop
// spends its tokens: definitions are sent once into a cached prefix, while every
// result is fresh input on every subsequent turn.
import { ActionError, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

const SEARCH_LIMIT = 10;
const BLOCK_LIMIT = 60;

/// Notion refuses any request that does not name a version, and pins behaviour
/// to the one named. Held here rather than passed in, because a version this
/// adapter was not written against is not a version it can read.
const VERSION = { "Notion-Version": "2026-03-11" };

interface RichText {
    plain_text?: string;
}

interface Page {
    id?: string;
    url?: string;
    last_edited_time?: string;
    properties?: Record<string, { type?: string; title?: RichText[] }>;
}


/// A page's title.
///
/// Notion has no `title` field: the title is whichever property happens to be
/// of type `title`, and its name is whatever the database column was called. So
/// it is found by type, not by name.
function titleOf(page: Page): string {
    for (const property of Object.values(page.properties ?? {})) {
        if (property?.type !== "title") continue;
        const text = (property.title ?? []).map((part) => part.plain_text ?? "").join("").trim();
        if (text) return text;
    }
    return "Untitled";
}

/// Notion's own id, with or without the dashes people paste.
function pageID(reference: string): string {
    const bare = reference.trim().split("?")[0].split("-").pop() ?? "";
    const id = /^[0-9a-f]{32}$/i.test(bare) ? bare : reference.trim();
    if (!/^[0-9a-f-]{32,36}$/i.test(id)) {
        throw new ActionError("invalid_params", `"${reference}" is not a Notion page id.`);
    }
    return id;
}

/// The readable text of one block, whatever kind it is.
///
/// Notion nests the same `rich_text` array under a key named after the block
/// type — `paragraph`, `heading_2`, `to_do` — so reading it by type name is the
/// only way that does not enumerate two dozen of them.
function blockText(block: Record<string, unknown>): string {
    const type = block.type as string | undefined;
    if (!type) return "";
    const body = block[type] as { rich_text?: RichText[] } | undefined;
    const text = (body?.rich_text ?? []).map((part) => part.plain_text ?? "").join("").trim();
    if (!text) return "";
    if (type.startsWith("heading")) return `## ${text}`;
    if (type === "to_do") return `- [ ] ${text}`;
    if (type.endsWith("list_item")) return `- ${text}`;
    return text;
}

export const NOTION_ACTIONS: ActionHandlers = {
    /// Pages this account can see, matching a phrase.
    ///
    /// Notion's search is over titles, not bodies — worth knowing, because it
    /// means a page is found by what it is called and not by what it says. The
    /// tool description says so, so the model stops rephrasing a query that was
    /// never going to match.
    search_pages: async (connection, params) => {
        const query = requireString(params, "query");
        const payload = await proxy(connection, "v1/search", {
            query,
            filter: { property: "object", value: "page" },
            sort: { timestamp: "last_edited_time", direction: "descending" },
            page_size: SEARCH_LIMIT,
        }, { headers: VERSION }) as { results?: Page[] } | null;

        return {
            results: (payload?.results ?? []).map((page) => ({
                id: page.id,
                title: titleOf(page),
                edited: page.last_edited_time,
                url: page.url,
            })),
        };
    },

    /// One page's text.
    ///
    /// Top-level blocks only. A Notion page nests arbitrarily deep, and walking
    /// it would turn one tool call into dozens of requests and put a document's
    /// entire outline into a turn — for a question that is almost always
    /// answered by the first screen of it.
    read_page: async (connection, params) => {
        const id = pageID(requireString(params, "page_id"));

        // Both addressed by the id alone, so neither waits on the other.
        const [page, blocks] = await Promise.all([
            proxy(connection, `v1/pages/${id}`, null, {
                method: "GET",
                headers: VERSION,
            }) as Promise<Page | null>,
            proxy(connection, `v1/blocks/${id}/children`, null, {
                method: "GET",
                query: { page_size: String(BLOCK_LIMIT) },
                headers: VERSION,
            }).catch(() => null) as Promise<{ results?: Record<string, unknown>[]; has_more?: boolean } | null>,
        ]);
        if (!page?.id) {
            throw new ActionError("not_found", "That page is not visible to this account.", 404);
        }

        const lines = (blocks?.results ?? []).map(blockText).filter(Boolean);
        return {
            id: page.id,
            title: titleOf(page),
            edited: page.last_edited_time,
            url: page.url,
            text: lines.join("\n"),
            truncated: blocks?.has_more === true,
        };
    },
};
