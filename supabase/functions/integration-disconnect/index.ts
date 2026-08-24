// integration-disconnect — ends one connection the caller made.
//
// The mirror of `integration-connect`, and it has to run here for the same
// reason: our OAuth client is what deletes a connection, and the client never
// holds it.
//
// Order matters. The broker first, our own row second: if we forgot the
// connection and then failed to reach Connect, the credential would keep living
// at the broker with nothing left pointing at it — a grant nobody can see and
// nobody can revoke. Failing loudly and leaving the row is recoverable; the
// other way round is not.
//
// Request  (POST /functions/v1/integration-disconnect): { "provider": "linear" }
// Response: { "ok": true }
import { json } from "../_shared/http.ts";
import { authenticate, adminClient } from "../_shared/supabase.ts";
import { isConnectableProvider } from "../_shared/integrations/registry.ts";
import { connectHeaders, connectURL, isConfigured } from "../_shared/integrations/pipedream.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!isConfigured) {
    console.error("pipedream connect is not configured");
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
    .select("broker_account_id")
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

  const response = await fetch(
    connectURL(`accounts/${encodeURIComponent(connection.broker_account_id as string)}`),
    { method: "DELETE", headers: await connectHeaders() },
  );

  // 404 means Connect has already forgotten it — the same end state we are
  // asking for, so it is a success rather than something to retry.
  if (!response.ok && response.status !== 404) {
    console.error(`connect delete failed: ${response.status} ${provider}`);
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
