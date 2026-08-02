// mcp — REMOTE MCP server (Streamable HTTP) for browser/desktop AI connectors:
// ChatGPT, Claude (claude.ai/Desktop), and Gemini CLI.
//
// AUTH: "authless" from the client's point of view — no OAuth, no API-key field.
// The per-user secret rides in the URL **path** (`/functions/v1/mcp/<token>`),
// which is what the three providers' research converged on as the only no-key
// path that actually works:
//   - ChatGPT: connector "No Authentication"; a token in the path (not the query
//     string, which the MCP spec forbids and ChatGPT drops).
//   - Claude: a custom connector connects authless as long as NOTHING on the
//     origin answers `/.well-known/oauth-*` with anything but a 404. Claude
//     probes `/.well-known/oauth-protected-resource/<path>` before connecting,
//     and Supabase's gateway 401s every unrouted path ("No API key found"),
//     which Claude reads as "OAuth required" and then fails at dynamic client
//     registration. So the link we hand users points at `hellonod.app/mcp/…`,
//     which Vercel rewrites here and where that probe gets a clean 404.
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
    "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";

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
