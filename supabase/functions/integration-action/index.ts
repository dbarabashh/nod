// integration-action — the single door between the chat's tool calls and any
// connected third-party product.
//
// The client decides *whether* to run a tool (and gates mutating ones behind the
// user's confirmation); this decides *what a tool may do*. Provider dispatch
// lives in `_shared/integrations/registry.ts`, so this file stays the same size
// whether we ship one integration or twenty.
//
// Two permissions, both held by `resolveConnection`: the person connected the
// product, and the organization permits it. The client hides a tool it may not
// use, but a client's hidden button is a courtesy, not the gate.
//
// Request  (POST /functions/v1/integration-action):
//   { "provider": "linear", "action": "search_issues", "params": { … }, "origin"?: "chat" | "app" }
// Response: { "result": … } or { "error": { "code", "message" } }
//
// Errors come back 200 with an `error` body when the model can do something
// about them — "not connected", "which team?" — because a failed HTTP call ends
// the agent turn while a readable error lets it recover or ask.
import { isObject, json } from "../_shared/http.ts";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { ActionError, resolveConnection } from "../_shared/integrations/pipedream.ts";
import { apiBase, handlerFor, hasActions } from "../_shared/integrations/registry.ts";
import { isMetered } from "../_shared/integrations/metering.ts";
import { recordUsage } from "../_shared/usage.ts";

// What a metered action costs us at the broker, per call, so the row carries a
// number the founder dashboard can add up. Pipedream's list rate for a Connect
// credit; a proxied read is one credit.
// Pipedream Connect Startup (checkout, 2026-09-09): $150 a month covers
// 10,000 credits, then $0.012 each up to 14,999 used, $0.0084 to 39,999,
// $0.0067 to 89,999. Booked at the first overage tier: the included pool is a
// fixed cost, and this is what the next credit costs once it is spent.
const CREDIT_COST_USD = 0.012;

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
  const origin = body?.origin;

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

  // The gate and the connection are two reads keyed on the same person, so
  // they are asked together; the gate is answered first. Read through the
  // resolver, like every other gate: a workspace's pool, or the person's own.
  const metered = isMetered(action, origin);
  const [gate, resolved] = await Promise.all([
    metered ? adminClient().rpc("resolve_entitlement", { p_user_id: user.id }) : Promise.resolve(null),
    resolveConnection(user.id, provider, apiBase(provider) ?? "").then(
      (connection) => ({ connection }),
      (error: unknown) => ({ error }),
    ),
  ]);

  let orgId: string | null = null;
  if (gate) {
    const { data: entitlement, error } = gate;
    if (error || !isObject(entitlement)) {
      console.warn(`integration action entitlement lookup failed (fail-open): ${error?.message ?? "unexpected shape"}`);
    } else {
      // `=== false`, not `!== true`: a resolver that predates the pool answers
      // with no key at all, and the app treats that as "no ceiling". The
      // gate says the same, or a function deployed ahead of its migration
      // refuses every read.
      if (entitlement.can_run_integration_action === false) {
        const active = entitlement.status === "active" || entitlement.status === "trialing";
        return json({
          error: {
            code: "integration_credits_exhausted",
            message: active
              ? "This period's integration credits are used up. Answer with what you already know; the user can add credits from Settings → Subscription, or a workspace owner or admin from Organization → Billing."
              : "The user has no active plan, so connected tools cannot be read. Answer with what you already know.",
          },
        }, 200);
      }
      orgId = entitlement.payer === "organization" && typeof entitlement.org_id === "string" ? entitlement.org_id : null;
    }
  }

  // Charged once the broker was actually called, whether or not the provider
  // answered well: Connect bills the attempt. Anything refused before that —
  // not connected, a missing parameter, an ambiguous team — costs nothing on
  // either side, so a model retrying bad arguments cannot drain the pool.
  const connection = "connection" in resolved ? resolved.connection : null;
  try {
    if (!connection) throw "error" in resolved ? resolved.error : new Error("no connection");
    const result = await handler(connection, params, { userId: user.id });
    console.info(`integration action ok: ${provider}.${action}`);
    return json({ result }, 200);
  } catch (error) {
    if (error instanceof ActionError) {
      console.warn(`integration action ${provider}.${action}: ${error.code}`);
      return json({ error: { code: error.code, message: error.message } }, 200);
    }
    console.error(`integration action ${provider}.${action} crashed: ${error}`);
    return json({ error: { code: "internal", message: "The action failed." } }, 500);
  } finally {
    if (metered && (connection?.proxied ?? 0) > 0) {
      await recordUsage({
        user_id: user.id,
        kind: "integration",
        model: `${provider}.${action}`,
        status: 200,
        cost_usd: CREDIT_COST_USD,
        task: "ask",
        org_id: orgId,
      });
    }
  }
});
