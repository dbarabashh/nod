// integration-disconnect — ends one connection the caller made.
//
// The mirror of `integration-connect`, and it has to run here for the same
// reason: the Nango secret key is what deletes a connection, and the client
// never holds it.
//
// Order matters. Nango first, our own row second: if we forgot the connection
// and then failed to reach Nango, the credential would keep living at the broker
// with nothing left pointing at it — a grant nobody can see and nobody can
// revoke. Failing loudly and leaving the row is recoverable; the other way round
// is not.
//
// Request  (POST /functions/v1/integration-disconnect): { "provider": "linear" }
// Response: { "ok": true }
import { json } from "../_shared/http.ts";
import { authenticate, adminClient } from "../_shared/supabase.ts";
import { isConnectableProvider } from "../_shared/integrations/registry.ts";

const NANGO_SECRET_KEY = Deno.env.get("NANGO_SECRET_KEY") ?? "";
const NANGO_CONNECTION_URL = "https://api.nango.dev/connection";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!NANGO_SECRET_KEY) {
    console.error("NANGO_SECRET_KEY is not set");
    return json({ error: "Integrations unavailable" }, 503);
  }

  const auth = await authenticate(req);
  if (auth instanceof Response) return auth;
  const { user } = auth;

  const body = await req.json().catch(() => null);
  const provider = body?.provider;
  if (typeof provider !== "string" || !isConnectableProvider(provider)) {
    return json({ error: "Unsupported provider" }, 400);
  }

  const admin = adminClient();
  const { data: connection, error: lookupError } = await admin
    .from("integration_connections")
    .select("nango_connection_id")
    .eq("user_id", user.id)
    .eq("provider", provider)
    .is("revoked_at", null)
    .maybeSingle();

  if (lookupError) {
    console.error(`integration-disconnect lookup failed: ${lookupError.message}`);
    return json({ error: "Could not read your connections" }, 500);
  }
  // Already gone. Answering yes is the honest reply to "make it so there is no
  // connection" — there isn't one.
  if (!connection) return json({ ok: true }, 200);

  const url = `${NANGO_CONNECTION_URL}/${encodeURIComponent(connection.nango_connection_id as string)}` +
    `?provider_config_key=${encodeURIComponent(provider)}`;
  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${NANGO_SECRET_KEY}` },
  });

  // 404 means Nango has already forgotten it — the same end state we are asking
  // for, so it is a success rather than something to retry.
  if (!response.ok && response.status !== 404) {
    console.error(`nango delete failed: ${response.status} ${provider}`);
    return json({ error: "Could not end the authorization" }, 502);
  }

  const { error: revokeError } = await admin
    .from("integration_connections")
    .update({ revoked_at: new Date().toISOString() })
    .eq("user_id", user.id)
    .eq("provider", provider)
    .is("revoked_at", null);

  if (revokeError) {
    console.error(`integration-disconnect revoke failed: ${revokeError.message}`);
    return json({ error: "Could not record the disconnection" }, 500);
  }

  // Anything the provider left with us goes with the connection — a trigger on
  // `integration_connections` does that, so every path that ends a connection
  // clears up, not just this one.
  console.info(`integration disconnected: ${provider}`);
  return json({ ok: true }, 200);
});
