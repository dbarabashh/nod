// Gmail, over its REST API.
//
// Reads, plus one write that stops short on purpose: a draft. "Write the
// follow-up" is the sentence every meeting ends with, and a draft answers it
// while leaving the send button — the only irrevocable part — in the person's
// own mail client. Nod never sends mail.
//
// Gmail's list endpoint returns ids and nothing else, so a search is one request
// plus one per message. That is the API's shape, not a choice — the only lever
// is how many, and it is set low on purpose.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { emailsOf, requireEmails, requireString } from "./params.ts";
import { base64URL } from "../crypto.ts";

const SEARCH_LIMIT = 5;
const HEADERS = ["Subject", "From", "To", "Date"];
const RECIPIENT_LIMIT = 20;

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

/// Bytes as base64, in chunks small enough for the call stack.
function base64(bytes: Uint8Array): string {
    let binary = "";
    for (let at = 0; at < bytes.length; at += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
    }
    return btoa(binary);
}

/// A header value, RFC 2047-encoded when it steps outside *printable* ASCII.
/// Printable, not all of ASCII: a control character in a header value is a
/// header injection — a CR-LF in a subject would end the Subject line and let
/// whatever follows pose as a header of its own — and B-encoding neutralises
/// it. Non-ASCII takes the same path so a bare Ukrainian subject arrives
/// intact.
export function headerValue(value: string): string {
    return /^[\x20-\x7e]*$/.test(value)
        ? value
        : `=?UTF-8?B?${base64(new TextEncoder().encode(value))}?=`;
}

/// One RFC 822 message, ready for Gmail's `raw` field once base64url-encoded.
/// The body travels base64 too, so no line of it can be mistaken for a header
/// and nothing depends on the transport being 8-bit clean.
///
/// `inReplyTo` is the original's own Message-ID header: `threadId` alone
/// threads the draft in the sender's mailbox, but only these headers thread
/// the sent mail in the recipients'.
export function draftMIME(
    to: string[],
    cc: string[],
    subject: string,
    body: string,
    inReplyTo?: string,
): string {
    const encoded = base64(new TextEncoder().encode(body));
    const lines = [
        `To: ${to.join(", ")}`,
        ...(cc.length > 0 ? [`Cc: ${cc.join(", ")}`] : []),
        `Subject: ${headerValue(subject)}`,
        ...(inReplyTo ? [`In-Reply-To: ${inReplyTo}`, `References: ${inReplyTo}`] : []),
        "MIME-Version: 1.0",
        'Content-Type: text/plain; charset="UTF-8"',
        "Content-Transfer-Encoding: base64",
        "",
        // RFC 2045 caps encoded lines at 76 characters.
        ...(encoded.match(/.{1,76}/g) ?? [""]),
    ];
    return lines.join("\r\n");
}

/// An empty optional list — `""`, `[]`, `","` — is how a model says "none";
/// failing the whole approved draft over it would be refusing an empty cc line.
export function recipients(params: Record<string, unknown>, key: string, required: boolean): string[] {
    return required
        ? requireEmails(params, key, RECIPIENT_LIMIT)
        : emailsOf(params, key, RECIPIENT_LIMIT);
}

/// The Message-ID of the newest message in a thread, for reply headers.
/// Best-effort: a thread we cannot read still gets a draft, just one that
/// relies on Gmail's own threading alone.
async function lastMessageID(connection: Connection, threadId: string): Promise<string | undefined> {
    const thread = await proxy(connection, `gmail/v1/users/me/threads/${encodeURIComponent(threadId)}`, null, {
        method: "GET",
        query: { format: "metadata", metadataHeaders: "Message-ID" },
    }).catch(() => null) as { messages?: Message[] } | null;
    const last = thread?.messages?.at(-1);
    // A provider-returned value still lands in a header line; strip the one
    // thing that could split it.
    return last ? header(last, "Message-ID")?.replace(/[\r\n]/g, "") : undefined;
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
                thread_id: entry.threadId,
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
            thread_id: found.threadId,
            subject: header(found, "Subject"),
            from: header(found, "From"),
            to: header(found, "To"),
            date: header(found, "Date"),
            text: plainText(found.payload) || found.snippet || "",
        };
    },

    /// Saves one draft in the person's own mailbox. Nothing is sent — the
    /// draft sits in Gmail's Drafts folder until they open, edit and send it
    /// themselves, which is the entire point of stopping here.
    create_draft: async (connection, params) => {
        const to = recipients(params, "to", true);
        const cc = recipients(params, "cc", false);
        const subject = requireString(params, "subject");
        const body = requireString(params, "body");
        const threadId = typeof params.thread_id === "string" && params.thread_id.trim()
            ? params.thread_id.trim()
            : undefined;

        const inReplyTo = threadId ? await lastMessageID(connection, threadId) : undefined;
        const mime = draftMIME(to, cc, subject, body, inReplyTo);
        const raw = base64URL(mime);

        const created = await proxy(connection, "gmail/v1/users/me/drafts", {
            message: { raw, ...(threadId ? { threadId } : {}) },
        }) as { id?: string; message?: { id?: string } } | null;
        if (!created?.id) {
            throw new ActionError("provider_error", "Gmail did not return the created draft.", 502);
        }
        return { draft_id: created.id, to, subject, sent: false };
    },
};
