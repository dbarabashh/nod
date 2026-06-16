// Shared Supabase access for Edge Functions: the service-role admin client and
// the JWT auth gate. Both were copy-pasted across create-checkout,
// customer-portal, llm-proxy, paddle-webhook, and share-ask — centralising them
// means a fix to token handling or client options lands once.
import { createClient, type SupabaseClient, type User } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "./http.ts";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// Service-role client (bypasses RLS). Never persists a session — these run
// stateless per request.
export function adminClient(): SupabaseClient {
    return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
    });
}

// Resolve the caller from their Supabase JWT. Returns the verified user, or a
// ready-to-return 401 Response when the Authorization header is missing or the
// token is rejected. Callers do: `const auth = await authenticate(req); if
// (auth instanceof Response) return auth; const { user } = auth;`
export async function authenticate(req: Request): Promise<{ user: User } | Response> {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Unauthenticated" }, 401);

    const token = authHeader.replace(/^Bearer\s+/i, "");
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: { user }, error } = await supabase.auth.getUser(token);
    if (error || !user) {
        console.warn(`JWT rejected: ${error?.message ?? "no user"}`);
        return json({ error: "Unauthenticated" }, 401);
    }
    return { user };
}
