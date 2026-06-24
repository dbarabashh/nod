#!/usr/bin/env node
// Nod MCP server — a thin, transport-only adapter over the `connect` edge
// function. It holds NO logic about meetings beyond formatting; all data access,
// auth, and per-user scoping live server-side. That keeps every MCP client
// (Claude, ChatGPT developer mode, Gemini CLI, Cursor, …) on an identical,
// read-only view that we can evolve without shipping a new server.
//
// Config (env):
//   NOD_MCP_TOKEN   required — a Nod personal access token (`nod_pat_…`),
//                   generated in Nod → Settings → Connections.
//   NOD_CONNECT_URL optional — override the API endpoint (defaults to prod).
//                   Point at the sandbox branch URL for testing.
import process from "node:process";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const TOKEN = process.env.NOD_MCP_TOKEN ?? "";
const CONNECT_URL = process.env.NOD_CONNECT_URL ?? "https://api.hellonod.app/functions/v1/connect";

if (!TOKEN) {
    console.error("NOD_MCP_TOKEN is not set. Generate one in Nod → Settings → Connections.");
    process.exit(1);
}

interface Meeting {
    id: string;
    title: string | null;
    started_at: string | null;
    ended_at: string | null;
    kind: string | null;
    language: string | null;
    summary: string | null;
    recap_json?: unknown;
}

interface TranscriptLine {
    source: string;
    text: string;
    idx: number;
    ts: string;
}

async function call(action: string, params: Record<string, unknown>): Promise<any> {
    const res = await fetch(CONNECT_URL, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${TOKEN}`,
        },
        body: JSON.stringify({ action, params }),
    });
    if (res.status === 401) {
        throw new Error("Nod rejected the token (401). It may be revoked — reissue one in Settings → Connections.");
    }
    if (!res.ok) {
        let detail = "";
        try {
            detail = ((await res.json()) as { error?: string })?.error ?? "";
        } catch {
            // ignore
        }
        throw new Error(`Nod API error ${res.status}${detail ? `: ${detail}` : ""}`);
    }
    return res.json();
}

function text(value: string) {
    return { content: [{ type: "text" as const, text: value }] };
}

function meetingLine(m: Meeting): string {
    const when = m.started_at ? new Date(m.started_at).toLocaleString() : "unknown time";
    const title = m.title?.trim() || "(untitled)";
    return `- ${title} — ${when} [${m.kind ?? "meeting"}] · id: ${m.id}`;
}

const server = new McpServer({ name: "nod", version: "0.1.0" });

server.tool(
    "list_meetings",
    "List the user's most recent Nod meetings (newest first). Returns titles, dates and ids. Use the id with get_meeting or get_transcript.",
    {
        limit: z.number().int().min(1).max(100).optional().describe("How many meetings to return (default 25)."),
        kind: z.enum(["meeting", "voice_note", "media"]).optional().describe("Filter by session kind."),
        before: z.string().optional().describe("ISO timestamp; only return meetings started before this."),
    },
    async ({ limit, kind, before }) => {
        const { meetings } = await call("list_meetings", { limit, kind, before });
        if (!meetings?.length) return text("No meetings found.");
        return text(meetings.map(meetingLine).join("\n"));
    },
);

server.tool(
    "get_meeting",
    "Get one meeting's recap/summary by id (without the full transcript).",
    {
        id: z.string().describe("The meeting id (a UUID from list_meetings)."),
    },
    async ({ id }) => {
        const { meeting } = await call("get_meeting", { id });
        const m = meeting as Meeting;
        const header = `# ${m.title?.trim() || "(untitled)"}\n` +
            `Started: ${m.started_at ?? "?"}  ·  Ended: ${m.ended_at ?? "?"}  ·  ` +
            `Kind: ${m.kind ?? "meeting"}  ·  Language: ${m.language ?? "?"}\n`;
        return text(`${header}\n## Summary\n${m.summary?.trim() || "(no summary)"}`);
    },
);

server.tool(
    "get_transcript",
    "Get the full transcript of a meeting by id, as speaker-labelled lines.",
    {
        id: z.string().describe("The meeting id (a UUID from list_meetings)."),
    },
    async ({ id }) => {
        const result = await call("get_transcript", { id });
        const meeting = result.meeting as Meeting;
        const lines = (result.lines ?? []) as TranscriptLine[];
        if (!lines.length) return text(`${meeting.title ?? "(untitled)"} has no transcript.`);
        const body = lines
            .map((l) => `[${l.source === "me" ? "Me" : l.source === "them" ? "Them" : l.source}]: ${l.text}`)
            .join("\n");
        return text(`# ${meeting.title?.trim() || "(untitled)"} — transcript\n\n${body}`);
    },
);

server.tool(
    "search_meetings",
    "Search the user's meetings by a term matched against title and summary.",
    {
        query: z.string().describe("Search term."),
        limit: z.number().int().min(1).max(100).optional().describe("Max results (default 25)."),
    },
    async ({ query, limit }) => {
        const { meetings } = await call("search_meetings", { query, limit });
        if (!meetings?.length) return text(`No meetings match "${query}".`);
        return text(meetings.map(meetingLine).join("\n"));
    },
);

const transport = new StdioServerTransport();
await server.connect(transport);
