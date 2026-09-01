// Notion, over its REST API.
//
// Reads, plus the two writes a meeting produces: a new page of notes, and an
// addition to an existing one. Both run only on the person's own instruction
// and stop at the desktop's approval card — nothing lands in a company's wiki
// unreviewed.
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
const WRITE_BLOCK_LIMIT = 50;

/// Notion refuses a rich_text element past 2000 characters; a paragraph is
/// split rather than refused, because "the note was too long" is not an error a
/// person can do anything with.
const TEXT_CHUNK = 2000;

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

/// The page an id names, checked against the title on the approval card.
///
/// The card shows a title while the wire carries an id, and this is what keeps
/// a model from pairing the right words with the wrong page — notes appended to
/// a page shared outside the team is the quiet failure this refuses.
async function confirmedPage(
    connection: Parameters<typeof proxy>[0],
    params: Record<string, unknown>,
    idKey: string,
    titleKey: string,
): Promise<Page> {
    const id = pageID(requireString(params, idKey));
    const expected = requireString(params, titleKey);

    const page = await proxy(connection, `v1/pages/${id}`, null, {
        method: "GET",
        headers: VERSION,
    }) as Page | null;
    if (!page?.id) {
        throw new ActionError("provider_error", "Notion did not return that page.", 502);
    }
    const actual = titleOf(page);
    if (actual.trim().toLowerCase() !== expected.trim().toLowerCase()) {
        throw new ActionError(
            "invalid_params",
            `That page is "${actual}", not "${expected}". Search again and use the id next to the right title.`,
        );
    }
    return page;
}

/// `content` as Notion paragraph blocks: one per line, long lines split.
function paragraphBlocks(content: string): Array<Record<string, unknown>> {
    const chunks: string[] = [];
    for (const line of content.split("\n").map((entry) => entry.trim()).filter(Boolean)) {
        let at = 0;
        while (at < line.length) {
            let end = Math.min(at + TEXT_CHUNK, line.length);
            // Never cut between the halves of a surrogate pair — the two lone
            // halves would be invalid Unicode Notion rejects outright.
            const last = line.charCodeAt(end - 1);
            if (end < line.length && last >= 0xD800 && last <= 0xDBFF) end -= 1;
            chunks.push(line.slice(at, end));
            at = end;
        }
    }
    if (chunks.length === 0) {
        throw new ActionError("invalid_params", "`content` is empty.");
    }
    if (chunks.length > WRITE_BLOCK_LIMIT) {
        throw new ActionError("invalid_params", `At most ${WRITE_BLOCK_LIMIT} paragraphs per call.`);
    }
    return chunks.map((chunk) => ({
        object: "block",
        type: "paragraph",
        paragraph: { rich_text: [{ type: "text", text: { content: chunk } }] },
    }));
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

    /// One new page under a page the account can already see.
    ///
    /// A parent is required rather than defaulted: Notion has no "wherever" —
    /// a page created loose in a workspace lands somewhere nobody asked for,
    /// and the model has `search_pages` to find where the notes belong.
    create_page: async (connection, params) => {
        const parent = await confirmedPage(connection, params, "parent_page_id", "parent_page_title");
        const title = requireString(params, "title");
        const content = requireString(params, "content");

        const created = await proxy(connection, "v1/pages", {
            parent: { page_id: parent.id },
            properties: { title: { title: [{ type: "text", text: { content: title } }] } },
            children: paragraphBlocks(content),
        }, { headers: VERSION }) as Page | null;
        if (!created?.id) {
            throw new ActionError("provider_error", "Notion did not return the created page.", 502);
        }
        return { id: created.id, title, url: created.url };
    },

    /// Appends paragraphs to the end of an existing page.
    append_page: async (connection, params) => {
        const page = await confirmedPage(connection, params, "page_id", "page_title");
        const content = requireString(params, "content");

        const appended = await proxy(connection, `v1/blocks/${page.id}/children`, {
            children: paragraphBlocks(content),
        }, { method: "PATCH", headers: VERSION }) as { results?: unknown[] } | null;
        if (!appended?.results) {
            throw new ActionError("provider_error", "Notion did not confirm the addition.", 502);
        }
        return { id: page.id, title: titleOf(page), appended_paragraphs: appended.results.length };
    },
};
