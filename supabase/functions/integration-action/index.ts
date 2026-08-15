// integration-action — the single door between the chat's tool calls and any
// connected third-party product.
//
// The client decides *whether* to run a tool (and gates mutating ones behind the
// user's confirmation); this decides *what a tool may do*. Provider dispatch
// lives in `_shared/integrations/registry.ts`, so this file stays the same size
// whether we ship one integration or twenty.
//
// Request  (POST /functions/v1/integration-action):
//   { "provider": "linear", "action": "search_issues", "params": { … } }
// Response: { "result": … } or { "error": { "code", "message" } }
//
// Errors come back 200 with an `error` body when the model can do something
// about them — "not connected", "which team?" — because a failed HTTP call ends
// the agent turn while a readable error lets it recover or ask.
import { json } from "../_shared/http.ts";
import { authenticate } from "../_shared/supabase.ts";
import { ActionError, resolveConnection } from "../_shared/integrations/nango.ts";
import { handlerFor, hasActions } from "../_shared/integrations/registry.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const auth = await authenticate(req);
  if (auth instanceof Response) return auth;
  const { user } = auth;

  const body = await req.json().catch(() => null);
  const provider = body?.provider;
  const action = body?.action;
  const params = (body?.params ?? {}) as Record<string, unknown>;

  if (typeof provider !== "string" || !hasActions(provider)) {
    return json({ error: { code: "unknown_provider", message: "Unknown provider." } }, 400);
  }
  if (typeof action !== "string") {
    return json({ error: { code: "invalid_params", message: "`action` is required." } }, 400);
  }

  const handler = handlerFor(provider, action);
  if (!handler) {
    return json({ error: { code: "unknown_action", message: `${provider} has no action \`${action}\`.` } }, 400);
  }

  try {
    const connection = await resolveConnection(user.id, provider);
    const result = await handler(connection, params);
    console.info(`integration action ok: ${provider}.${action}`);
    return json({ result }, 200);
  } catch (error) {
    if (error instanceof ActionError) {
      console.warn(`integration action ${provider}.${action}: ${error.code}`);
      return json({ error: { code: error.code, message: error.message } }, 200);
    }
    console.error(`integration action ${provider}.${action} crashed: ${error}`);
    return json({ error: { code: "internal", message: "The action failed." } }, 500);
  }
});
