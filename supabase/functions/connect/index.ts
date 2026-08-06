// connect — provider-agnostic data API for a user's OWN AI client.
//
// This is the trust boundary that turns a personal access token into a
// per-user, read-only view of meetings. It powers the `nod-mcp` MCP server
// today and is shaped so other transports (a remote MCP HTTP endpoint, an
// OpenAPI surface for ChatGPT Actions / Gemini extensions) can sit on top of
// the same actions without change.
//
// Auth — like `share-ask`, NOT a Supabase JWT (`verify_jwt = false`):
//   - `Authorization: Bearer nod_pat_<hex>`. We sha256 the token and match it
//     against an un-revoked `connections.token_hash`. The server never stored
//     the raw token (the client hashed it on-device), so the gate is hash-only.
//   - A revoked/garbage/expired token → 401. Nothing reaches the data layer
//     without resolving to a single `user_id`.
//
// Request (POST /functions/v1/connect):
//   { "action": "list_meetings" | "get_meeting" | "get_transcript" | "search_meetings",
//     "params": { ... } }
import { adminClient } from "../_shared/supabase.ts";
import { json as jsonBase } from "../_shared/http.ts";
import {
  CONNECTOR_MIGRATION_URL,
  legacyConnectorExpired,
  legacyConnectorHeaders,
} from "../_shared/legacy-connector.ts";
import { resolveConnectionUser } from "../_shared/connections.ts";
import {
  getMeeting,
  getTranscript,
  listMeetings,
  searchMeetings,
} from "../_shared/meetings.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number): Response {
  return jsonBase(body, status, {
    ...CORS_HEADERS,
    ...legacyConnectorHeaders(),
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method Not Allowed" }, 405);
  }
  if (legacyConnectorExpired()) {
    return json({
      error: "legacy_connector_retired",
      migration_url: CONNECTOR_MIGRATION_URL,
    }, 410);
  }

  const admin = adminClient();
  const token = (req.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  const userId = await resolveConnectionUser(admin, token);
  if (!userId) {
    return json({ error: "Unauthenticated" }, 401);
  }

  let body: { action?: unknown; params?: Record<string, unknown> };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const action = typeof body.action === "string" ? body.action : "";
  const params = (body.params ?? {}) as Record<string, unknown>;

  try {
    switch (action) {
      case "list_meetings":
        return json({
          meetings: await listMeetings(admin, userId, {
            limit: params.limit as number | undefined,
            kind: params.kind as string | undefined,
            before: params.before as string | undefined,
          }),
        }, 200);

      case "get_meeting": {
        const meeting = await getMeeting(
          admin,
          userId,
          String(params.id ?? ""),
        );
        if (!meeting) return json({ error: "Meeting not found" }, 404);
        return json({ meeting }, 200);
      }

      case "get_transcript": {
        const result = await getTranscript(
          admin,
          userId,
          String(params.id ?? ""),
        );
        if (!result) return json({ error: "Meeting not found" }, 404);
        return json(result, 200);
      }

      case "search_meetings":
        return json({
          meetings: await searchMeetings(
            admin,
            userId,
            String(params.query ?? ""),
            params.limit as number | undefined,
          ),
        }, 200);

      default:
        return json({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (e) {
    console.error(
      `action ${action} failed: ${e instanceof Error ? e.message : e}`,
    );
    return json({ error: "Server error" }, 500);
  }
});
