import {
  createMcpHandler,
  McpServer,
} from "npm:@modelcontextprotocol/server@2.0.0";
import * as z from "npm:zod@4.4.3";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  authenticateConnector,
  oauthChallenge,
} from "../_shared/connector-auth.ts";
import {
  boundedMcpResult,
  FOUNDER_ANALYTICS_PERMISSION,
  founderIdentityAllowed,
  type FounderReport,
} from "../_shared/founder-mcp.ts";
import { json as jsonBase } from "../_shared/http.ts";

const ENABLED = Deno.env.get("FOUNDER_MCP_ENABLED") === "true";
const RESOURCE_URI = Deno.env.get("FOUNDER_MCP_RESOURCE_URI") ??
  "https://nod-founder-dashboard.vercel.app/mcp";
const AUTHORIZATION_SERVER = Deno.env.get("MCP_AUTHORIZATION_SERVER") ??
  `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;
const RESOURCE_METADATA_URI =
  Deno.env.get("FOUNDER_MCP_RESOURCE_METADATA_URI") ??
    "https://nod-founder-dashboard.vercel.app/.well-known/oauth-protected-resource";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, mcp-protocol-version, mcp-session-id",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Expose-Headers": "mcp-session-id, www-authenticate",
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

const REPORTS = [
  "overview",
  "acquisition",
  "activation",
  "retention",
  "monetization",
  "usage_cost",
  "product_analytics",
  "communications",
] as const satisfies readonly FounderReport[];

type AuditContext = {
  actorId: string;
  clientId: string;
};

function json(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return jsonBase(body, status, { ...CORS_HEADERS, ...headers });
}

function callerClient(token: string): SupabaseClient {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
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

function originAllowed(req: Request): boolean {
  const origin = req.headers.get("Origin");
  if (!origin) return true;
  try {
    const url = new URL(origin);
    return url.protocol === "https:" || url.hostname === "localhost";
  } catch {
    return false;
  }
}

function withHeaders(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function runReadRpc(
  client: SupabaseClient,
  audit: AuditContext,
  tool: string,
  rpc: string,
  args: Record<string, unknown>,
) {
  const startedAt = performance.now();
  const { data, error } = await client.rpc(rpc, args);
  const status = error ? "error" : "ok";
  console.info(JSON.stringify({
    event: "founder_mcp_tool",
    actor_id: audit.actorId,
    client_id: audit.clientId,
    tool,
    status,
    duration_ms: Math.round(performance.now() - startedAt),
  }));
  if (error) {
    return {
      content: [{
        type: "text" as const,
        text: "The analytics request could not be completed.",
      }],
      isError: true,
    };
  }
  const bounded = boundedMcpResult(data);
  const output = { result: bounded.value, truncated: bounded.truncated };
  return {
    content: [{ type: "text" as const, text: JSON.stringify(output) }],
    structuredContent: output,
  };
}

function createServer(
  client: SupabaseClient,
  audit: AuditContext,
): McpServer {
  const server = new McpServer({
    name: "nod-founder-analytics",
    title: "Nod Founder Analytics",
    version: "1.0.0",
  });

  server.registerTool(
    "get_founder_report",
    {
      title: "Get founder analytics report",
      description:
        "Return one read-only Nod company analytics report. Use the narrowest report and time window that answers the question.",
      inputSchema: z.object({
        report: z.enum(REPORTS),
        days: z.number().int().min(1).max(365).optional(),
        platform: z.enum(["macos", "ios"]).optional(),
        weeks: z.number().int().min(1).max(52).optional(),
      }),
      outputSchema: z.object({ result: z.unknown(), truncated: z.boolean() }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    ({ report, days = 30, platform, weeks = 8 }) =>
      runReadRpc(
        client,
        audit,
        "get_founder_report",
        "founder_mcp_report",
        {
          p_report: report,
          p_days: days,
          p_platform: platform ?? null,
          p_weeks: weeks,
        },
      ),
  );

  server.registerTool(
    "list_recent_signups",
    {
      title: "List recent Nod signups",
      description:
        "List bounded recent signups with lifecycle and consent-safe attribution. Rows are pseudonymous by default. Set include_identity only when the founder explicitly asks who a user is or requests an email/name.",
      inputSchema: z.object({
        days: z.number().int().min(1).max(365).optional(),
        limit: z.number().int().min(1).max(100).optional(),
        attribution_status: z.enum(["attributed", "unattributed"]).optional(),
        include_identity: z.boolean().default(false),
      }),
      outputSchema: z.object({ result: z.unknown(), truncated: z.boolean() }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    ({ days = 30, limit = 50, attribution_status, include_identity }) =>
      runReadRpc(
        client,
        audit,
        "list_recent_signups",
        "founder_mcp_recent_signups",
        {
          p_days: days,
          p_limit: limit,
          p_attribution_status: attribution_status ?? null,
          p_include_identity: include_identity,
        },
      ),
  );

  server.registerTool(
    "find_user",
    {
      title: "Find a Nod user",
      description:
        "Find a user only after the founder provides a non-empty email, name, or user ID. Returns bounded identity, lifecycle, usage, attribution, and founder notes.",
      inputSchema: z.object({ query: z.string().trim().min(1).max(120) }),
      outputSchema: z.object({ result: z.unknown(), truncated: z.boolean() }),
      annotations: READ_ONLY_ANNOTATIONS,
      _meta: SECURITY_META,
    },
    ({ query }) =>
      runReadRpc(
        client,
        audit,
        "find_user",
        "founder_mcp_find_user",
        { p_query: query },
      ),
  );

  return server;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);

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
  if (!ENABLED) return json({ error: "founder_mcp_disabled" }, 503);

  const identity = await authenticateConnector(
    req,
    RESOURCE_URI,
    AUTHORIZATION_SERVER,
    RESOURCE_METADATA_URI,
    FOUNDER_ANALYTICS_PERMISSION,
  );
  if (identity instanceof Response) {
    return withHeaders(identity);
  }
  if (!founderIdentityAllowed(identity)) {
    return json(
      { error: "insufficient_access" },
      403,
      {
        "WWW-Authenticate": oauthChallenge(
          RESOURCE_METADATA_URI,
          "insufficient_scope",
        ),
      },
    );
  }

  const handler = createMcpHandler(
    () =>
      createServer(callerClient(identity.token), {
        actorId: identity.user.id,
        clientId: identity.claims.client_id ?? "unknown",
      }),
    {
      responseMode: "json",
      onerror: () =>
        console.error(JSON.stringify({
          event: "founder_mcp_protocol_error",
          actor_id: identity.user.id,
          client_id: identity.claims.client_id ?? "unknown",
          status: "error",
        })),
    },
  );
  return withHeaders(await handler.fetch(req));
});
