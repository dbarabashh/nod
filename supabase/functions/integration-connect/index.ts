// integration-connect — mints a Nango Connect session for the caller.
//
// The macOS app has no JS runtime and must not hold the Nango secret key, so it
// never speaks to Nango directly. It POSTs here with its Supabase JWT, gets back
// a `connect_link` (a 30-minute magic link), and opens it in the user's browser.
// Nango runs the OAuth dance and keeps the credentials; we learn the result from
// the `auth`/`creation` webhook, never from the client.
//
// Request  (POST /functions/v1/integration-connect): { "provider": "linear" }
// Response: { "connectLink": "https://…", "expiresAt": "2026-…" }
import { json } from "../_shared/http.ts";
import { authenticate } from "../_shared/supabase.ts";
import { isKnownProvider } from "../_shared/integrations/registry.ts";

const NANGO_SECRET_KEY = Deno.env.get("NANGO_SECRET_KEY") ?? "";
const NANGO_SESSIONS_URL = "https://api.nango.dev/connect/sessions";

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
  if (typeof provider !== "string" || !isKnownProvider(provider)) {
    return json({ error: "Unsupported provider" }, 400);
  }

  const response = await fetch(NANGO_SESSIONS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${NANGO_SECRET_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      allowed_integrations: [provider],
      tags: { end_user_id: user.id },
    }),
  });

  if (!response.ok) {
    console.error(`nango session failed: ${response.status} ${provider}`);
    return json({ error: "Could not start authorization" }, 502);
  }

  const session = await response.json().catch(() => null);
  const connectLink = session?.data?.connect_link;
  if (typeof connectLink !== "string") {
    console.error("nango session returned no connect_link");
    return json({ error: "Could not start authorization" }, 502);
  }

  console.info(`nango session created: ${provider}`);
  return json({ connectLink, expiresAt: session?.data?.expires_at ?? null }, 200);
});
