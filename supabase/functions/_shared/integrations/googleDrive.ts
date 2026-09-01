// Google Drive, over its REST API.
//
// Read-only: find a file, and read its text. Somebody says "the pricing doc"
// and the answers worth having are which file that is — a link a person can
// open and check — and what it actually says.
import { ActionError, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

const LIMIT = 10;
const FIELDS = "files(id,name,mimeType,webViewLink,modifiedTime,owners(displayName))";

interface File {
    id?: string;
    name?: string;
    mimeType?: string;
    webViewLink?: string;
    modifiedTime?: string;
    size?: string;
    owners?: { displayName?: string }[];
}

/// Drive's own vocabulary for what a file is, in words a person uses.
const KINDS: Record<string, string> = {
    "application/vnd.google-apps.document": "doc",
    "application/vnd.google-apps.spreadsheet": "sheet",
    "application/vnd.google-apps.presentation": "slides",
    "application/vnd.google-apps.folder": "folder",
    "application/pdf": "pdf",
};

/// How each kind of file yields text: Google's own formats export, anything
/// already textual downloads as itself, and everything else — an image, a video,
/// a binary — has no text to read.
const EXPORTS: Record<string, string> = {
    "application/vnd.google-apps.document": "text/plain",
    "application/vnd.google-apps.spreadsheet": "text/csv",
    "application/vnd.google-apps.presentation": "text/plain",
};

const TEXTUAL = /^(text\/|application\/(json|xml|csv))/;

/// Enough to answer "what does the doc say" without putting a novel into the
/// turn — every tool result is re-read by the model on each later turn.
const TEXT_LIMIT = 20_000;

/// A download is read whole before it is cut to `TEXT_LIMIT`, so a file is
/// refused by its declared size first — a hundred-megabyte CSV would otherwise
/// be materialised in the worker for the sake of its first twenty thousand
/// characters. Google's own formats carry no size and export capped anyway.
const DOWNLOAD_LIMIT = 5_000_000;

/// Escapes a Drive query literal. A file name with an apostrophe would
/// otherwise close the string and make the whole query invalid.
function quoted(value: string): string {
    return `'${value.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

export const GOOGLE_DRIVE_ACTIONS: ActionHandlers = {
    /// Files whose name or contents match.
    ///
    /// `fullText contains` rather than only `name contains`: people describe a
    /// document by what is in it at least as often as by what it is called, and
    /// Drive indexes both.
    search_files: async (connection, params) => {
        const query = requireString(params, "query");
        const payload = await proxy(connection, "drive/v3/files", null, {
            method: "GET",
            query: {
                q: `(name contains ${quoted(query)} or fullText contains ${quoted(query)}) and trashed = false`,
                pageSize: String(LIMIT),
                orderBy: "modifiedTime desc",
                fields: FIELDS,
                // Shared drives are where a company's documents actually live;
                // without these two the search only ever sees "My Drive".
                supportsAllDrives: "true",
                includeItemsFromAllDrives: "true",
            },
        }) as { files?: File[] } | null;

        return {
            files: (payload?.files ?? []).map((file) => ({
                id: file.id,
                name: file.name,
                kind: KINDS[file.mimeType ?? ""] ?? "file",
                owner: file.owners?.[0]?.displayName,
                modified: file.modifiedTime,
                url: file.webViewLink,
            })),
        };
    },

    /// One file's text.
    read_file: async (connection, params) => {
        const id = requireString(params, "file_id");
        const file = await proxy(connection, `drive/v3/files/${encodeURIComponent(id)}`, null, {
            method: "GET",
            query: { fields: "id,name,mimeType,webViewLink,modifiedTime,size", supportsAllDrives: "true" },
        }) as File | null;
        if (!file?.id) {
            throw new ActionError("not_found", "That file is not visible to this account.", 404);
        }

        const exported = EXPORTS[file.mimeType ?? ""];
        if (!exported && !TEXTUAL.test(file.mimeType ?? "")) {
            throw new ActionError(
                "invalid_params",
                `"${file.name}" is ${KINDS[file.mimeType ?? ""] ?? file.mimeType ?? "a file"} — it has no text to read. Hand the user its link instead.`,
            );
        }
        if (!exported && Number(file.size ?? 0) > DOWNLOAD_LIMIT) {
            throw new ActionError(
                "invalid_params",
                `"${file.name}" is too large to read here. Hand the user its link instead.`,
            );
        }

        const text = await proxy(
            connection,
            exported
                ? `drive/v3/files/${encodeURIComponent(id)}/export`
                : `drive/v3/files/${encodeURIComponent(id)}`,
            null,
            {
                method: "GET",
                parse: "text",
                query: exported
                    ? { mimeType: exported }
                    : { alt: "media", supportsAllDrives: "true" },
            },
        ) as string;

        return {
            id: file.id,
            name: file.name,
            kind: KINDS[file.mimeType ?? ""] ?? "file",
            modified: file.modifiedTime,
            url: file.webViewLink,
            text: text.slice(0, TEXT_LIMIT),
            truncated: text.length > TEXT_LIMIT,
        };
    },
};
