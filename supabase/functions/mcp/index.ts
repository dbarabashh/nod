// mcp — REMOTE MCP server (Streamable HTTP) for browser/desktop AI connectors:
// ChatGPT, Claude (claude.ai/Desktop), and Gemini CLI.
//
// AUTH: "authless" from the client's point of view — no OAuth, no API-key field.
// The per-user secret rides in the URL **path** (`/functions/v1/mcp/<token>`),
// which is what the three providers' research converged on as the only no-key
// path that actually works:
//   - ChatGPT: connector "No Authentication"; a token in the path (not the query
//     string, which the MCP spec forbids and ChatGPT drops).
//   - Claude: a custom connector connects authless as long as we NEVER return a
//     401 with OAuth metadata and expose no `/.well-known/oauth-*` — so we don't.
//   - Gemini CLI: a plain remote URL with no declared auth.
// The token still resolves to ONE `user_id`; every read is scoped to it, so a
// connector only ever reaches that user's own meetings.
//
// ChatGPT additionally requires `search` + `fetch` tools (specific shapes,
// dual structuredContent + JSON-string content) for a read-only connector; we
// provide those plus human-readable `list_meetings` / `get_transcript`.
//
// Same `connections` token + same `_shared/meetings.ts` as the local path — this
// is purely a second transport. Read-only.
import { adminClient } from "../_shared/supabase.ts";
import { json as jsonBase } from "../_shared/http.ts";
import { resolveConnectionUser } from "../_shared/connections.ts";
import { getTranscript, listMeetings, type Meeting, searchMeetings } from "../_shared/meetings.ts";

const PROTOCOL_VERSION = "2025-06-18";
const MEETING_URL = (id: string) => `https://hellonod.app/m/${id}`;

// Nod brand mark, advertised as a data: URI in `serverInfo.icons` (to non-Claude
// clients) so those that render a custom-connector logo show Nod instead of a
// generic globe. 128px PNG, inlined — Supabase edge forces text/plain on bodies,
// so a separately-served image wouldn't work.
const ICON_PNG_B64 =
    "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAARGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAADoAEAAwAAAAEAAQAAoAIABAAAAAEAAACAoAMABAAAAAEAAACAAAAAAEiOBHcAAAGfaVRYdFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOmV4aWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vZXhpZi8xLjAvIj4KICAgICAgICAgPGV4aWY6UGl4ZWxYRGltZW5zaW9uPjEwMjQ8L2V4aWY6UGl4ZWxYRGltZW5zaW9uPgogICAgICAgICA8ZXhpZjpQaXhlbFlEaW1lbnNpb24+MTAyNDwvZXhpZjpQaXhlbFlEaW1lbnNpb24+CiAgICAgIDwvcmRmOkRlc2NyaXB0aW9uPgogICA8L3JkZjpSREY+CjwveDp4bXBtZXRhPgpVgmNYAAAG7UlEQVR4Ae2dW6gVZRTHPeaNym6WGaVYpt2QKCG6C0rRDRHK6iEopKJeJHoIeqqeih57MSKyooduB3zo4svppaxIVELsnkkWpaZplliip9+yEc8lt883M9/Mt/Pf/dvc/aWlk26geBQuAY4udL7dr0bmZfbbOTvo0bRaz1c/1HaXgOUWvjvLy8F8HC4BldrHEjjG52RpG8vamkypirmk6bkA865H1KshiBDADjxOCvDa78epmww2L1mbsYYkMeWI9sl4FWYwA7ERDjrauxaTajN2p7OBexQhgWqeILb1mf4ptaim2hbXYOf45GNyrGAHYv1nLzXaSULIzfwHFWmzLITcL7lWMAOxDnrmZkZ/0w5PHKNhi5yiA4F7FCCDHN4C7eTe+/xhNSvZyETvq6luyZIY7Du5VjACiLx0PzynJs71JvMY5zSGHkRkH9ypGACOD5PDc/idf25ZDDqU56HYBHCxdeX0Lc8ihdDXdLoDShWvhfwxIAM6VIAFIAM4ZcF6+JoAE4JwB5+VrAkgAzhlwXr4mgATgnAHn5WsCSADOGXBeviaABOCcAeflawJIAM4ZcF6+JoAE4JwB5+VrAkgAzhlwXr4mgATgnAHn5WsCSADOGXBeviaABOCcAeflawJIAM4ZcF6+JoAE4JwB5+VrAkgAzhlwXr4mgATgnAHn5WsCSADOGXBeviaABBDMQPAXEQV7rL7hxOouKnvIIYeRRQT3atzIlR2e29ekxmzfwVVtL62tzVN5R/Y18rvKL0+yMsevtE1SqJyKATEgBsSAGBADYkAMiAExIAbEgBgQA2JADIgBMSAGxIAYEANiQAyIATEgBsSAGBADoxn4Fy2/cloQ+Q4VAAAAAElFTkSuQmCC";

const CORS_HEADERS: Record<string, string> = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type, mcp-session-id, mcp-protocol-version",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
    return jsonBase(body, status, CORS_HEADERS);
}

function bearer(req: Request): string | null {
    const m = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
    return m ? m[1].trim() : null;
}

// Token from the URL path (`…/mcp/<token>`), preferred; falls back to `?key=` and
// an Authorization header for clients (Claude Code, Gemini CLI) that allow those.
function extractToken(req: Request, url: URL): string | null {
    const parts = url.pathname.split("/").filter(Boolean);
    const i = parts.lastIndexOf("mcp");
    if (i >= 0 && parts.length > i + 1) return decodeURIComponent(parts[i + 1]);
    return url.searchParams.get("key") ?? bearer(req);
}

function rpcResult(id: unknown, result: unknown) {
    return { jsonrpc: "2.0", id, result };
}

function rpcError(id: unknown, code: number, message: string) {
    return { jsonrpc: "2.0", id, error: { code, message } };
}

const TOOLS = [
    {
        name: "search",
        description: "Search the user's Nod meetings by keyword (matches title and summary). Returns matching meetings, each with an id to fetch.",
        inputSchema: {
            type: "object",
            properties: { query: { type: "string", description: "Search keywords." } },
            required: ["query"],
        },
    },
    {
        name: "fetch",
        description: "Fetch one Nod meeting's full content (summary + transcript) by id.",
        inputSchema: {
            type: "object",
            properties: { id: { type: "string", description: "Meeting id, from search/list_meetings." } },
            required: ["id"],
        },
    },
    {
        name: "list_meetings",
        description: "List the user's most recent Nod meetings (newest first).",
        inputSchema: {
            type: "object",
            properties: {
                limit: { type: "number", description: "How many (default 25, max 100)." },
                kind: { type: "string", enum: ["meeting", "voice_note", "media"] },
            },
        },
    },
    {
        name: "get_transcript",
        description: "Get a meeting's full transcript by id, as speaker-labelled lines.",
        inputSchema: {
            type: "object",
            properties: { id: { type: "string", description: "Meeting id." } },
            required: ["id"],
        },
    },
];

function meetingLine(m: Meeting): string {
    const when = m.started_at ? new Date(m.started_at).toISOString().slice(0, 16).replace("T", " ") : "unknown time";
    return `- ${m.title?.trim() || "(untitled)"} — ${when} [${m.kind ?? "meeting"}] · id: ${m.id}`;
}

function transcriptBody(lines: Array<{ source: string; text: string }>): string {
    return lines
        .map((l) => `${l.source === "me" ? "Me" : l.source === "them" ? "Them" : l.source}: ${l.text}`)
        .join("\n");
}

function truncationNote(truncated: boolean): string {
    return truncated ? "\n\n… (transcript truncated — first 5000 lines only)" : "";
}

interface ToolResult {
    content: Array<{ type: "text"; text: string }>;
    structuredContent?: unknown;
    isError?: boolean;
}

// deno-lint-ignore no-explicit-any
async function handleToolCall(name: string, args: any, admin: any, userId: string): Promise<ToolResult> {
    switch (name) {
        case "search": {
            const q = String(args?.query ?? "").trim();
            const meetings = (q
                ? await searchMeetings(admin, userId, q, args?.limit)
                : await listMeetings(admin, userId, { limit: args?.limit })) as Meeting[];
            const results = meetings.map((m) => ({
                id: m.id,
                title: m.title?.trim() || "(untitled)",
                text: (m.summary ?? "").slice(0, 400),
                url: MEETING_URL(m.id),
            }));
            const payload = { results };
            return { content: [{ type: "text", text: JSON.stringify(payload) }], structuredContent: payload };
        }
        case "fetch": {
            const id = String(args?.id ?? "");
            const r = await getTranscript(admin, userId, id);
            if (!r) {
                const payload = { id, title: "Not found", text: "", url: MEETING_URL(id), metadata: {} };
                return { content: [{ type: "text", text: JSON.stringify(payload) }], structuredContent: payload };
            }
            const m = r.meeting as Meeting;
            const summary = m.summary?.trim() ? `Summary:\n${m.summary.trim()}\n\n` : "";
            const text = `${summary}Transcript:\n${transcriptBody(r.lines) || "(none)"}${truncationNote(r.truncated)}`;
            const payload = {
                id,
                title: m.title?.trim() || "(untitled)",
                text,
                url: MEETING_URL(id),
                metadata: { started_at: m.started_at, ended_at: m.ended_at, kind: m.kind, language: m.language },
            };
            return { content: [{ type: "text", text: JSON.stringify(payload) }], structuredContent: payload };
        }
        case "list_meetings": {
            const meetings = (await listMeetings(admin, userId, { limit: args?.limit, kind: args?.kind })) as Meeting[];
            return { content: [{ type: "text", text: meetings.length ? meetings.map(meetingLine).join("\n") : "No meetings found." }] };
        }
        case "get_transcript": {
            const r = await getTranscript(admin, userId, String(args?.id ?? ""));
            if (!r) return { content: [{ type: "text", text: "Meeting not found." }] };
            const m = r.meeting as Meeting;
            return { content: [{ type: "text", text: `# ${m.title?.trim() || "(untitled)"} — transcript\n\n${transcriptBody(r.lines) || "(none)"}${truncationNote(r.truncated)}` }] };
        }
        default:
            throw new Error(`Unknown tool: ${name}`);
    }
}

// deno-lint-ignore no-explicit-any
async function handleMessage(msg: any, admin: any, userId: string): Promise<unknown | null> {
    const { id, method, params } = msg ?? {};

    switch (method) {
        case "initialize": {
            // Claude refuses to connect when serverInfo carries fields outside the
            // negotiated protocol version (it rejected `icons`/`title`). Other
            // clients (ChatGPT, Gemini) tolerate them and can render the brand
            // logo — so we advertise the icon to everyone EXCEPT Claude, which
            // gets the minimal, proven shape. Detected via the client's own name.
            const clientName = String((params?.clientInfo as { name?: string } | undefined)?.name ?? "").toLowerCase();
            const strictClient = clientName.includes("claude");
            const serverInfo = {
                name: "nod",
                version: "0.1.0",
                ...(strictClient ? {} : {
                    title: "Nod",
                    icons: [{ src: `data:image/png;base64,${ICON_PNG_B64}`, mimeType: "image/png", sizes: "128x128" }],
                }),
            };
            return rpcResult(id, {
                protocolVersion: params?.protocolVersion ?? PROTOCOL_VERSION,
                capabilities: { tools: {} },
                serverInfo,
            });
        }
        case "ping":
            return rpcResult(id, {});
        case "tools/list":
            return rpcResult(id, { tools: TOOLS });
        case "tools/call": {
            try {
                return rpcResult(id, await handleToolCall(params?.name, params?.arguments ?? {}, admin, userId));
            } catch (e) {
                return rpcResult(id, {
                    content: [{ type: "text", text: `Error: ${e instanceof Error ? e.message : e}` }],
                    isError: true,
                });
            }
        }
        default:
            if (typeof method === "string" && method.startsWith("notifications/")) return null;
            return rpcError(id ?? null, -32601, `Method not found: ${method}`);
    }
}

Deno.serve(async (req: Request): Promise<Response> => {
    const url = new URL(req.url);

    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (req.method === "GET") {
        // A human opening the link in a browser does a GET. Supabase edge serves
        // function bodies as text/plain (nosniff), so return a clean sentence —
        // not HTML markup, which would show as raw source. AI clients use POST.
        if ((req.headers.get("Accept") ?? "").includes("text/html")) {
            return new Response(
                "This is your private Nod connector endpoint, and it's working.\n\n" +
                    "Don't open it in a browser — paste this whole link into your AI app's connector " +
                    "(custom MCP server) settings in Claude, ChatGPT, or the Gemini CLI, and your AI " +
                    "will read your meetings directly.",
                { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8", ...CORS_HEADERS } },
            );
        }
        return json({ error: "Method Not Allowed" }, 405);
    }
    if (req.method !== "POST") {
        return json({ error: "Method Not Allowed" }, 405);
    }

    const admin = adminClient();
    // Resolve to a 401 with NO WWW-Authenticate / OAuth metadata, so authless
    // clients (Claude) don't fall into an OAuth discovery flow they can't finish.
    const userId = await resolveConnectionUser(admin, extractToken(req, url) ?? "");
    if (!userId) {
        return json({ error: "Invalid or missing connector key" }, 401);
    }

    let body: unknown;
    try {
        body = await req.json();
    } catch {
        return json(rpcError(null, -32700, "Parse error"), 200);
    }

    if (Array.isArray(body)) {
        const responses = (await Promise.all(body.map((m) => handleMessage(m, admin, userId)))).filter((r) => r !== null);
        return responses.length ? json(responses) : new Response(null, { status: 202, headers: CORS_HEADERS });
    }

    const response = await handleMessage(body, admin, userId);
    return response === null ? new Response(null, { status: 202, headers: CORS_HEADERS }) : json(response);
});
