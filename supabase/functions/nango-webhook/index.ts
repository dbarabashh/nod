// nango-webhook — the only writer of `integration_connections`.
//
// Nango owns the OAuth result, so the connection id reaches us here and not
// through the app: a client that could POST its own `nango_connection_id` could
// point its row at somebody else's linked account. Runs with `verify_jwt =
// false` (Nango sends no Supabase JWT) and is gated instead by the HMAC that
// Nango signs every delivery with.
//
// Signature: hex HMAC-SHA256 of the raw body, keyed with the *webhook signing
// key* from Environment Settings → Webhooks. That is a different secret from
// the API secret key `integration-connect` uses.
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { verifyHmacSha256Hex } from "../_shared/crypto.ts";
import { directoryTargetOrg, importDirectory, isDirectorySource } from "../_shared/integrations/directory.ts";

const NANGO_WEBHOOK_SECRET = Deno.env.get("NANGO_WEBHOOK_SECRET") ?? "";
const SIGNATURE_HEADER = "x-nango-hmac-sha256";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!NANGO_WEBHOOK_SECRET) {
    console.error("NANGO_WEBHOOK_SECRET is not set");
    return json({ error: "Webhook not configured" }, 503);
  }

  const signature = req.headers.get(SIGNATURE_HEADER);
  const rawBody = await req.text();
  if (!signature || !(await verifyHmacSha256Hex(NANGO_WEBHOOK_SECRET, rawBody, signature))) {
    console.warn("nango webhook rejected: bad signature");
    return json({ error: "Invalid signature" }, 401);
  }

  const event = JSON.parse(rawBody) as Record<string, unknown>;

  // Nango sends sync/forward events down the same URL. Acknowledge anything we
  // don't handle — a non-2xx here just buys us a retry loop.
  if (event.type !== "auth" || event.operation !== "creation") {
    return json({ ok: true }, 200);
  }
  if (event.success !== true) {
    console.warn(`nango auth failed: ${event.providerConfigKey}`);
    return json({ ok: true }, 200);
  }

  const provider = event.providerConfigKey;
  const connectionId = event.connectionId;
  const userId = (event.tags as Record<string, unknown> | undefined)?.end_user_id;
  if (typeof provider !== "string" || typeof connectionId !== "string" || typeof userId !== "string") {
    console.error("nango auth webhook missing provider, connection or end_user_id");
    return json({ error: "Malformed payload" }, 400);
  }

  // Reconnecting mints a fresh Nango connection, so the row is replaced rather
  // than added to: one live link per user per provider.
  const { error } = await adminClient()
    .from("integration_connections")
    .upsert({
      user_id: userId,
      provider,
      nango_connection_id: connectionId,
      connected_at: new Date().toISOString(),
      revoked_at: null,
    }, { onConflict: "user_id,provider" });

  if (error) {
    console.error(`integration_connections upsert failed: ${error.message}`);
    return json({ error: "Could not store connection" }, 500);
  }

  console.info(`integration connected: ${provider}`);

  // The moment a company's stack is connected is the moment its roster can be
  // read, and reading it is what makes the product usable before anybody has
  // been invited to Nod. Administrators only — a member linking their own
  // account is not setting the company up, and their workspace's members are
  // not the company's colleagues.
  //
  // After the connection is stored and outside its success path: a directory we
  // could not read is a slower first run, not a failed connection, and telling
  // Nango this delivery failed would only make it send the same one again.
  if (isDirectorySource(provider)) {
    try {
      const admin = adminClient();
      const orgId = await directoryTargetOrg(admin, userId);
      if (orgId) {
        await importDirectory(admin, { id: connectionId, provider }, orgId);
      }
    } catch (error) {
      console.warn(`directory import after connecting ${provider} failed: ${error}`);
    }
  }

  return json({ ok: true }, 200);
});
