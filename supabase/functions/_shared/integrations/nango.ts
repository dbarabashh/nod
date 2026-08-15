// Everything that touches Nango. Providers never import `fetch` themselves —
// they get a connection and a proxy call, so credentials, base URL and the
// secret key stay in exactly one place no matter how many providers we add.
import { adminClient } from "../supabase.ts";

const NANGO_SECRET_KEY = Deno.env.get("NANGO_SECRET_KEY") ?? "";
const NANGO_PROXY_URL = "https://api.nango.dev/proxy";

export class ActionError extends Error {
    readonly code: string;
    readonly status: number;

    constructor(code: string, message: string, status = 400) {
        super(message);
        this.code = code;
        this.status = status;
    }
}

export interface Connection {
    id: string;
    provider: string;
}

/// The caller's live connection for a provider, or an error the model can act
/// on — "not connected" is a normal answer, not a failure.
export async function resolveConnection(userId: string, provider: string): Promise<Connection> {
    const { data, error } = await adminClient()
        .from("integration_connections")
        .select("nango_connection_id")
        .eq("user_id", userId)
        .eq("provider", provider)
        .is("revoked_at", null)
        .maybeSingle();

    if (error) {
        console.error(`integration_connections lookup failed: ${error.message}`);
        throw new ActionError("lookup_failed", "Could not read your connections.", 500);
    }
    if (!data) {
        throw new ActionError(
            "not_connected",
            `${provider} is not connected. Ask the user to connect it in Settings → Integrations.`,
            409,
        );
    }
    return { id: data.nango_connection_id as string, provider };
}

export interface ProxyOptions {
    /// Defaults to POST, which is what a GraphQL provider wants. A REST one that
    /// reads — a calendar — is a GET with no body at all.
    method?: "GET" | "POST" | "PATCH" | "DELETE";
    query?: Record<string, string | undefined>;
}

/// One proxied call to the provider's own API. Nango injects the access token
/// and refreshes it when it has expired, which is why no token appears here.
export async function proxy(
    connection: Connection,
    path: string,
    body: unknown,
    options: ProxyOptions = {},
): Promise<unknown> {
    if (!NANGO_SECRET_KEY) {
        throw new ActionError("unconfigured", "Integrations are not configured.", 503);
    }

    const method = options.method ?? "POST";
    const search = new URLSearchParams();
    for (const [key, value] of Object.entries(options.query ?? {})) {
        if (value !== undefined) search.set(key, value);
    }
    const url = search.size > 0
        ? `${NANGO_PROXY_URL}/${path}?${search}`
        : `${NANGO_PROXY_URL}/${path}`;

    const response = await fetch(url, {
        method,
        headers: {
            "Authorization": `Bearer ${NANGO_SECRET_KEY}`,
            "Connection-Id": connection.id,
            "Provider-Config-Key": connection.provider,
            "Content-Type": "application/json",
        },
        body: method === "GET" ? undefined : JSON.stringify(body),
    });

    const payload = await response.json().catch(() => null);
    if (!response.ok) {
        console.error(`nango proxy ${connection.provider}/${path} failed: ${response.status}`);
        // 401 here means the user revoked access on the provider's side; saying
        // so lets the model tell them to reconnect instead of retrying.
        const code = response.status === 401 ? "reauthorize" : "provider_error";
        throw new ActionError(code, `${connection.provider} rejected the request.`, 502);
    }
    return payload;
}
