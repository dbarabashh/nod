// integration-connect — mints a Connect token for the caller.
//
// The macOS app has no JS runtime and must not hold our OAuth client secret, so
// it never speaks to Pipedream directly. It POSTs here with its Supabase JWT,
// gets back a `connectLink` (a short-lived, single-use magic link), and opens it
// in the user's browser. Pipedream runs the OAuth dance and keeps the
// credentials; we learn the result by reading it back from Connect, never from
// the client.
//
// Request  (POST /functions/v1/integration-connect): { "provider": "linear" }
// Response: { "connectLink": "https://…", "expiresAt": "2026-…" }
import { json } from "../_shared/http.ts";
import { authenticate } from "../_shared/supabase.ts";
import { appSlug, isConnectableProvider } from "../_shared/integrations/registry.ts";
import { connectHeaders, connectURL, isConfigured } from "../_shared/integrations/pipedream.ts";

const WEBHOOK_URL = Deno.env.get("INTEGRATION_WEBHOOK_URL") ?? "";

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
  const slug = appSlug(provider) ?? provider;

  const response = await fetch(connectURL("tokens"), {
    method: "POST",
    headers: await connectHeaders(),
    body: JSON.stringify({
      // The Supabase user id *is* the external user id. One identity on both
      // sides is what lets every later call be scoped to the person, and what
      // makes a connection a person rather than an account for billing.
      external_user_id: user.id,
      ...(WEBHOOK_URL ? { webhook_uri: WEBHOOK_URL } : {}),
    }),
  });

  const session = await response.json().catch(() => null);
  const link = session?.connect_link_url;
  if (!response.ok || typeof link !== "string") {
    console.error(`connect token failed: ${response.status} ${provider}`);
    return json({ error: "Could not start authorization" }, 502);
  }

  // The app is chosen on the link rather than in the token, so one token can
  // never be walked into authorizing a product the user did not pick.
  const connectLink = `${link}${link.includes("?") ? "&" : "?"}app=${encodeURIComponent(slug)}`;

  console.info(`connect token created: ${provider}`);
  return json({ connectLink, expiresAt: session?.expires_at ?? null }, 200);
});
