// Gmail, over its REST API.
//
// Read-only, and deliberately shallow. What a meeting needs is "what did they
// write back", which a subject line and a snippet usually answer; a tool that
// could send mail from a conversation is a different product with a different
// approval story.
//
// Gmail's list endpoint returns ids and nothing else, so a search is one request
// plus one per message. That is the API's shape, not a choice — the only lever
// is how many, and it is set low on purpose.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

const SEARCH_LIMIT = 5;
const HEADERS = ["Subject", "From", "To", "Date"];

interface Message {
    id?: string;
    threadId?: string;
    snippet?: string;
    payload?: {
        headers?: { name?: string; value?: string }[];
        mimeType?: string;
        body?: { data?: string };
        parts?: Message["payload"][];
    };
}


function header(message: Message, name: string): string | undefined {
    return message.payload?.headers
        ?.find((entry) => entry.name?.toLowerCase() === name.toLowerCase())
        ?.value;
}

/// Gmail bodies are base64url, and a multipart message hides the readable half
/// somewhere in its parts. Walks to the first `text/plain`, which is the one a
/// model should read — the html alternative is the same words wrapped in markup
/// that would cost several times the tokens.
function plainText(part: Message["payload"]): string {
    if (!part) return "";
    if (part.mimeType === "text/plain" && part.body?.data) {
        try {
            const normalised = part.body.data.replace(/-/g, "+").replace(/_/g, "/");
            return new TextDecoder().decode(
                Uint8Array.from(atob(normalised), (character) => character.charCodeAt(0)),
            );
        } catch {
            return "";
        }
    }
    for (const child of part.parts ?? []) {
        const text = plainText(child);
        if (text) return text;
    }
    return "";
}

async function message(connection: Connection, id: string, format: string, extra: string[] = []) {
    return await proxy(connection, `gmail/v1/users/me/messages/${id}`, null, {
        method: "GET",
        query: {
            format,
            ...(extra.length > 0 ? { metadataHeaders: extra.join(",") } : {}),
        },
    }) as Message | null;
}

export const GMAIL_ACTIONS: ActionHandlers = {
    /// Messages matching a Gmail query.
    ///
    /// Gmail's own search syntax passes through — `from:`, `subject:`,
    /// `newer_than:7d` are what somebody means when they say "what did Acme send
    /// last week", and re-inventing them behind our own parameters would lose
    /// exactly those questions.
    search_messages: async (connection, params) => {
        const query = requireString(params, "query");
        const listed = await proxy(connection, "gmail/v1/users/me/messages", null, {
            method: "GET",
            query: { q: query, maxResults: String(SEARCH_LIMIT) },
        }) as { messages?: { id?: string }[] } | null;

        const ids = (listed?.messages ?? []).map((entry) => entry.id).filter((id): id is string => !!id);
        const messages = await Promise.all(
            ids.map((id) => message(connection, id, "metadata", HEADERS)),
        );

        return {
            results: messages.filter((entry): entry is Message => entry !== null).map((entry) => ({
                id: entry.id,
                subject: header(entry, "Subject"),
                from: header(entry, "From"),
                date: header(entry, "Date"),
                preview: entry.snippet,
            })),
        };
    },

    /// One message in full.
    read_message: async (connection, params) => {
        const id = requireString(params, "message_id");
        const found = await message(connection, id, "full");
        if (!found?.id) {
            throw new ActionError("not_found", "That message is not in this mailbox.", 404);
        }
        return {
            id: found.id,
            subject: header(found, "Subject"),
            from: header(found, "From"),
            to: header(found, "To"),
            date: header(found, "Date"),
            text: plainText(found.payload) || found.snippet || "",
        };
    },
};
