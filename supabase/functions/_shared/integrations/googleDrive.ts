// Google Drive, over its REST API.
//
// Search only, and read-only. Somebody says "the pricing doc" and the answer
// worth having is which file that is and where it lives — a link a person can
// open and check.
//
// Deliberately no `read_file`. A Google Doc's text comes from the export
// endpoint, which answers `text/plain` rather than JSON, and the proxy every
// adapter shares parses JSON. Adding a second, untyped path through it for one
// action would cost more than it is worth while Notion already answers "what did
// we write".
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
};
