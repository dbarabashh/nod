import {
  createMcpHandler,
  McpServer,
} from "npm:@modelcontextprotocol/server@2.0.0";
import {
  registerAppResource,
  registerAppTool,
  RESOURCE_MIME_TYPE,
} from "npm:@modelcontextprotocol/ext-apps@1.7.5/server";
import * as z from "npm:zod@4.4.3";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  authenticateConnector,
  CONNECTOR_PERMISSION,
  oauthChallenge,
} from "../_shared/connector-auth.ts";
import { resolveConnectionUser } from "../_shared/connections.ts";
import { json as jsonBase } from "../_shared/http.ts";
import {
  CONNECTOR_MIGRATION_URL,
  legacyConnectorExpired,
  legacyConnectorHeaders,
} from "../_shared/legacy-connector.ts";
import {
  getTranscriptPage,
  listMeetings,
  type Meeting,
  searchMeetings,
} from "../_shared/meetings.ts";
import { adminClient } from "../_shared/supabase.ts";

const APP_RESOURCE_URI = "ui://nod/meeting-browser.html";
const MEETING_URL = (id: string) => `https://hellonod.app/m/${id}`;
const OAUTH_ENABLED = Deno.env.get("MCP_OAUTH_ENABLED") === "true";
const RESOURCE_URI = Deno.env.get("MCP_RESOURCE_URI") ??
  "https://hellonod.app/mcp";
const AUTHORIZATION_SERVER = Deno.env.get("MCP_AUTHORIZATION_SERVER") ??
  `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;
const RESOURCE_METADATA_URI = Deno.env.get("MCP_RESOURCE_METADATA_URI") ??
  "https://hellonod.app/.well-known/oauth-protected-resource";
const APP_ASSET_ORIGIN = assetOrigin(
  Deno.env.get("MCP_APP_ASSET_ORIGIN") ?? "https://hellonod.app",
);
const APP_DOMAIN = Deno.env.get("MCP_APP_DOMAIN") ?? undefined;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, mcp-protocol-version, mcp-session-id",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Expose-Headers":
    "mcp-session-id, www-authenticate, deprecation, sunset, link",
};

const READ_ONLY_ANNOTATIONS = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};

const SECURITY_META = {
  securitySchemes: [{ type: "oauth2", scopes: ["openid", "email"] }],
};

const meetingSchema = z.object({
  id: z.string(),
  title: z.string(),
  startedAt: z.string().nullable(),
  endedAt: z.string().nullable(),
  kind: z.string().nullable(),
  language: z.string().nullable(),
  summary: z.string().nullable(),
  url: z.string(),
});

const transcriptLineSchema = z.object({
  source: z.string(),
  text: z.string(),
  index: z.number(),
  timestamp: z.string(),
});

function assetOrigin(value: string): string {
  try {
    return new URL(value).origin;
  } catch {
    return "https://hellonod.app";
  }
}

function json(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return jsonBase(body, status, { ...CORS_HEADERS, ...headers });
}

function meetingPayload(meeting: Meeting) {
  return {
    id: meeting.id,
    title: meeting.title?.trim() || "(untitled)",
    startedAt: meeting.started_at,
    endedAt: meeting.ended_at,
    kind: meeting.kind,
    language: meeting.language,
    summary: meeting.summary,
    url: MEETING_URL(meeting.id),
  };
}

function transcriptText(
  lines: Array<{ source: string; text: string }>,
): string {
  return lines.map((line) => `${line.source}: ${line.text}`).join("\n");
}

function transcriptLines(
  lines: Array<{ source: string; text: string; idx: number; ts: string }>,
) {
  return lines.map((line) => ({
    source: line.source,
    text: line.text,
    index: line.idx,
    timestamp: line.ts,
  }));
}

function protectedResourceMetadata() {
  return {
    resource: RESOURCE_URI,
    authorization_servers: [AUTHORIZATION_SERVER],
    bearer_methods_supported: ["header"],
    scopes_supported: ["openid", "email"],
    resource_documentation: "https://hellonod.app/connectors",
  };
}

function appHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<meta name="color-scheme" content="light dark" />
<title>Nod Meeting Browser</title>
<link rel="stylesheet" href="${APP_ASSET_ORIGIN}/assets/mcp-app-v1.css" />
</head>
<body>
<div id="root"></div>
<script type="module" src="${APP_ASSET_ORIGIN}/assets/mcp-app-v1.js"></script>
</body>
</html>`;
}

function createServer(admin: SupabaseClient, userId: string): McpServer {
  const server = new McpServer({ name: "nod", title: "Nod", version: "1.0.0" });

  server.registerTool(
    "search",
    {
      title: "Search Nod meetings",
      description:
        "Search the user's Nod meeting titles and summaries. Returns IDs for fetch.",
      inputSchema: z.object({
        query: z.string().describe(
          "Search keywords. Use an empty string to return recent meetings.",
        ),
        limit: z.number().int().min(1).max(100).optional(),
      }),
      outputSchema: z.object({
        results: z.array(z.object({
          id: z.string(),
          title: z.string(),
          text: z.string(),
          url: z.string(),
        })),
      }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    async ({ query, limit }) => {
      const meetings = query.trim()
        ? await searchMeetings(admin, userId, query, limit)
        : await listMeetings(admin, userId, { limit });
      const output = {
        results: meetings.map((meeting) => ({
          id: meeting.id,
          title: meeting.title?.trim() || "(untitled)",
          text: (meeting.summary ?? "").slice(0, 800),
          url: MEETING_URL(meeting.id),
        })),
      };
      return {
        content: [{ type: "text", text: JSON.stringify(output) }],
        structuredContent: output,
      };
    },
  );

  server.registerTool(
    "fetch",
    {
      title: "Fetch a Nod meeting",
      description:
        "Fetch one meeting's metadata, summary, and first transcript page by ID.",
      inputSchema: z.object({ id: z.string().min(1) }),
      outputSchema: z.object({
        id: z.string(),
        title: z.string(),
        text: z.string(),
        url: z.string(),
        metadata: meetingSchema.nullable(),
        nextCursor: z.string().nullable(),
      }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    async ({ id }) => {
      const result = await getTranscriptPage(admin, userId, id);
      if (!result) {
        const output = {
          id,
          title: "Not found",
          text: "",
          url: MEETING_URL(id),
          metadata: null,
          nextCursor: null,
        };
        return {
          content: [{ type: "text", text: JSON.stringify(output) }],
          structuredContent: output,
        };
      }
      const meeting = meetingPayload(result.meeting as Meeting);
      const summary = meeting.summary?.trim()
        ? `Summary:\n${meeting.summary.trim()}\n\n`
        : "";
      const page = transcriptText(result.lines);
      const continuation = result.nextCursor
        ? "\n\nMore transcript is available with get_transcript."
        : "";
      const output = {
        id,
        title: meeting.title,
        text: `${summary}Transcript:\n${page || "(none)"}${continuation}`,
        url: meeting.url,
        metadata: meeting,
        nextCursor: result.nextCursor,
      };
      return {
        content: [{ type: "text", text: JSON.stringify(output) }],
        structuredContent: output,
      };
    },
  );

  server.registerTool(
    "list_meetings",
    {
      title: "List Nod meetings",
      description: "List the user's most recent Nod meetings, newest first.",
      inputSchema: z.object({
        limit: z.number().int().min(1).max(100).optional(),
        kind: z.enum(["meeting", "voice_note", "media"]).optional(),
        before: z.string().datetime().optional(),
      }),
      outputSchema: z.object({
        meetings: z.array(meetingSchema),
        nextBefore: z.string().nullable(),
      }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    async ({ limit, kind, before }) => {
      const meetings = await listMeetings(admin, userId, {
        limit,
        kind,
        before,
      });
      const output = {
        meetings: meetings.map(meetingPayload),
        nextBefore: meetings.length > 0
          ? meetings[meetings.length - 1].started_at
          : null,
      };
      return {
        content: [{
          type: "text",
          text: output.meetings.length
            ? output.meetings.map((meeting) =>
              `${meeting.title} — ${
                meeting.startedAt ?? "unknown time"
              } · ${meeting.id}`
            ).join("\n")
            : "No meetings found.",
        }],
        structuredContent: output,
      };
    },
  );

  server.registerTool(
    "get_transcript",
    {
      title: "Get transcript page",
      description:
        "Get one page of a meeting transcript. Pass nextCursor to continue.",
      inputSchema: z.object({
        id: z.string().min(1),
        cursor: z.string().optional(),
        limit: z.number().int().min(1).max(250).optional(),
      }),
      outputSchema: z.object({
        meeting: meetingSchema,
        lines: z.array(transcriptLineSchema),
        nextCursor: z.string().nullable(),
        characterLimited: z.boolean(),
      }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    async ({ id, cursor, limit }) => {
      const result = await getTranscriptPage(admin, userId, id, {
        cursor,
        limit,
      });
      if (!result) {
        return {
          content: [{ type: "text", text: "Meeting not found." }],
          isError: true,
        };
      }
      const output = {
        meeting: meetingPayload(result.meeting as Meeting),
        lines: transcriptLines(result.lines),
        nextCursor: result.nextCursor,
        characterLimited: result.characterLimited,
      };
      return {
        content: [{
          type: "text",
          text: `${transcriptText(result.lines) || "(none)"}${
            result.nextCursor ? "\n\nMore transcript is available." : ""
          }`,
        }],
        structuredContent: output,
      };
    },
  );

  registerAppTool(
    server,
    "render_meeting_browser",
    {
      title: "Open Nod meeting browser",
      description:
        "Open a read-only browser for recent or searched Nod meetings.",
      inputSchema: z.object({ query: z.string().optional() }),
      outputSchema: z.object({
        meetings: z.array(meetingSchema),
        query: z.string(),
      }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: {
        ...SECURITY_META,
        ui: { resourceUri: APP_RESOURCE_URI },
        "openai/outputTemplate": APP_RESOURCE_URI,
        "openai/toolInvocation/invoking": "Loading Nod meetings…",
        "openai/toolInvocation/invoked": "Nod meetings ready",
      },
    },
    async ({ query = "" }) => {
      const meetings = query.trim()
        ? await searchMeetings(admin, userId, query, 25)
        : await listMeetings(admin, userId, { limit: 25 });
      const output = { meetings: meetings.map(meetingPayload), query };
      return {
        content: [{
          type: "text",
          text: output.meetings.length
            ? `Opened ${output.meetings.length} read-only Nod meetings.`
            : "No Nod meetings found.",
        }],
        structuredContent: output,
      };
    },
  );

  registerAppResource(
    server,
    "Nod meeting browser",
    APP_RESOURCE_URI,
    {},
    async () => ({
      contents: [{
        uri: APP_RESOURCE_URI,
        mimeType: RESOURCE_MIME_TYPE,
        text: appHtml(),
        _meta: {
          ui: {
            csp: { resourceDomains: [APP_ASSET_ORIGIN], connectDomains: [] },
            ...(APP_DOMAIN ? { domain: APP_DOMAIN } : {}),
          },
          "openai/widgetCSP": {
            resource_domains: [APP_ASSET_ORIGIN],
            connect_domains: [],
          },
          "openai/widgetPrefersBorder": true,
        },
      }],
    }),
  );

  return server;
}

function legacyToken(req: Request, url: URL): string | null {
  const parts = url.pathname.split("/").filter(Boolean);
  const mcpIndex = parts.lastIndexOf("mcp");
  if (
    mcpIndex >= 0 && parts.length > mcpIndex + 1 &&
    parts[mcpIndex + 1] !== ".well-known"
  ) {
    return decodeURIComponent(parts[mcpIndex + 1]);
  }
  const queryToken = url.searchParams.get("key");
  if (queryToken) return queryToken;
  const match = (req.headers.get("Authorization") ?? "").match(
    /^Bearer\s+(nod_pat_[^\s]+)$/i,
  );
  return match?.[1] ?? null;
}

function withHeaders(
  response: Response,
  headers: Record<string, string>,
): Response {
  const merged = new Headers(response.headers);
  for (const [key, value] of Object.entries({ ...CORS_HEADERS, ...headers })) {
    merged.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: merged,
  });
}

function originAllowed(req: Request): boolean {
  const origin = req.headers.get("Origin");
  if (!origin) return true;
  try {
    return new URL(origin).protocol === "https:" ||
      new URL(origin).hostname === "localhost";
  } catch {
    return false;
  }
}

async function serveMcp(
  req: Request,
  admin: SupabaseClient,
  userId: string,
  headers: Record<string, string> = {},
) {
  const handler = createMcpHandler(() => createServer(admin, userId), {
    responseMode: "json",
    onerror: (error) =>
      console.error(
        JSON.stringify({ event: "mcp_sdk_error", message: error.message }),
      ),
  });
  return withHeaders(await handler.fetch(req), headers);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const requestId = crypto.randomUUID();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (!originAllowed(req)) return json({ error: "invalid_origin" }, 403);

  if (
    req.method === "GET" &&
    url.pathname.endsWith("/.well-known/oauth-protected-resource")
  ) {
    return json(protectedResourceMetadata());
  }

  const token = legacyToken(req, url);
  if (token) {
    if (legacyConnectorExpired()) {
      return json(
        {
          error: "legacy_connector_retired",
          migration_url: CONNECTOR_MIGRATION_URL,
        },
        410,
        legacyConnectorHeaders(),
      );
    }
    const admin = adminClient();
    const userId = await resolveConnectionUser(admin, token);
    if (!userId) {
      return json(
        { error: "Invalid or missing connector key" },
        401,
        legacyConnectorHeaders(),
      );
    }
    console.info(
      JSON.stringify({
        event: "legacy_mcp_request",
        request_id: requestId,
        method: req.method,
      }),
    );
    return serveMcp(req, admin, userId, legacyConnectorHeaders());
  }

  if (!OAUTH_ENABLED) return json({ error: "oauth_connector_disabled" }, 503);

  const identity = await authenticateConnector(
    req,
    RESOURCE_URI,
    AUTHORIZATION_SERVER,
    RESOURCE_METADATA_URI,
  );
  if (identity instanceof Response) {
    return withHeaders(identity, {
      "WWW-Authenticate": oauthChallenge(
        RESOURCE_METADATA_URI,
        "invalid_token",
      ),
    });
  }

  console.info(JSON.stringify({
    event: "oauth_mcp_request",
    request_id: requestId,
    method: req.method,
    client_id: identity.claims.client_id,
    permission: CONNECTOR_PERMISSION,
  }));
  return serveMcp(req, adminClient(), identity.user.id);
});
