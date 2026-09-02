// Everything that touches Pipedream Connect. Providers never import `fetch`
// themselves — they get a connection and a proxy call, so credentials, base URL
// and the OAuth client stay in exactly one place no matter how many providers we
// add.
import { adminClient } from "../supabase.ts";
import { base64URL } from "../crypto.ts";
import { ActionError } from "./errors.ts";
import { assertProviderPermitted } from "./policy.ts";

// Re-exported because every adapter and both doors already import it from here,
// and where the class is declared is not worth a change in eighteen files.
export { ActionError };

const CLIENT_ID = Deno.env.get("PIPEDREAM_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("PIPEDREAM_CLIENT_SECRET") ?? "";
const PROJECT_ID = Deno.env.get("PIPEDREAM_PROJECT_ID") ?? "";
// `development` keeps test connections off the production external-user count,
// which is what Connect bills on.
const ENVIRONMENT = Deno.env.get("PIPEDREAM_ENVIRONMENT") ?? "production";

const OAUTH_URL = "https://api.pipedream.com/v1/oauth/token";
const API_BASE = "https://api.pipedream.com/v1/connect";

export const isConfigured = Boolean(CLIENT_ID && CLIENT_SECRET && PROJECT_ID);

export interface Connection {
    /// Connect's account id (`apn_…`).
    id: string;
    provider: string;
    /// Every proxied call is scoped to the person as well as the account, so a
    /// stolen account id alone addresses nothing.
    externalUserId: string;
    /// The provider's own API root, from `registry.ts`. Passed in rather than
    /// looked up here: which API a provider speaks is adapter knowledge, and a
    /// second table of it in the broker module is a second table to keep in
    /// step with the first.
    base: string;
}

/// The caller's live connection for a provider, or an error the model can act
/// on — "not connected" is a normal answer, not a failure.
///
/// Holds both permissions, so that no caller has to remember either. The person
/// connected the product and the organization permits it; a `Connection` is the
/// object every provider call needs, so gating its construction is what makes
/// "Nod may act here" structurally true instead of something five doors each
/// check for themselves. The two paths that build a `Connection` by hand — the
/// calendar sweep and the roster import — ask `barredUsers` for the same reason
/// in the shape their fan-out needs.
export async function resolveConnection(userId: string, provider: string, base: string): Promise<Connection> {
    await assertProviderPermitted(userId, provider);

    const { data, error } = await adminClient()
        .from("integration_connections")
        .select("broker_account_id")
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
    return { id: data.broker_account_id as string, provider, externalUserId: userId, base };
}

/// A client-credentials token for our own OAuth client, cached until shortly
/// before it expires.
///
/// Cached because every proxied call needs one and an edge instance serves many:
/// minting one per call would double the round trips on the surface where a
/// second of silence is the whole cost. Module scope, so it dies with the
/// instance rather than outliving a rotated secret.
/// The *mint*, not the token. Every proxied call awaits this, and the callers
/// above fan out — fifteen concurrent lookups on a cold instance would each have
/// found the cache empty and minted their own.
let cachedToken: { value: Promise<string>; expiresAt: number } | null = null;

function accessToken(): Promise<string> {
    if (!isConfigured) {
        return Promise.reject(new ActionError("unconfigured", "Integrations are not configured.", 503));
    }
    if (cachedToken && Date.now() < cachedToken.expiresAt) return cachedToken.value;

    // Optimistic expiry, replaced once the real lifetime is known. A refused
    // mint clears the slot so the next caller retries rather than awaiting a
    // rejection forever.
    const mint = mintToken().catch((error) => {
        cachedToken = null;
        throw error;
    });
    cachedToken = { value: mint, expiresAt: Date.now() + 60_000 };
    return mint;
}

async function mintToken(): Promise<string> {
    const response = await fetch(OAUTH_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            grant_type: "client_credentials",
            client_id: CLIENT_ID,
            client_secret: CLIENT_SECRET,
        }),
    });
    const payload = await response.json().catch(() => null);
    const token = payload?.access_token;
    if (!response.ok || typeof token !== "string") {
        console.error(`pipedream oauth failed: ${response.status}`);
        throw new ActionError("unconfigured", "Integrations are not configured.", 503);
    }
    // A minute of headroom: the token is checked before a call, not during it.
    const ttl = typeof payload.expires_in === "number" ? payload.expires_in : 3600;
    if (cachedToken) cachedToken.expiresAt = Date.now() + (ttl - 60) * 1000;
    return token;
}

/// Headers every Connect call carries. Exported because the connect/disconnect
/// functions talk to Connect's own endpoints rather than through the proxy.
export async function connectHeaders(): Promise<Record<string, string>> {
    return {
        "Authorization": `Bearer ${await accessToken()}`,
        "x-pd-environment": ENVIRONMENT,
        "Content-Type": "application/json",
    };
}

export function connectURL(path: string): string {
    return `${API_BASE}/${PROJECT_ID}/${path}`;
}

/// One authenticated read of the broker's API, or null.
///
/// Every caller wanted the same three lines — mint, fetch, give up on a
/// non-2xx — and each hand-written copy was one forgotten `connectHeaders()`
/// away from an unauthenticated request.
export async function brokerGET(url: string): Promise<unknown | null> {
    const response = await fetch(url, { method: "GET", headers: await connectHeaders() });
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
        console.error(`broker GET failed: ${response.status} ${new URL(url).pathname}`);
        return null;
    }
    return payload;
}

/// The broker's own catalogue, which is not scoped to a project.
export function appsURL(path = ""): string {
    return `https://api.pipedream.com/v1/apps${path}`;
}

export interface ProxyOptions {
    /// Defaults to POST, which is what a GraphQL provider wants. A REST one that
    /// reads — a calendar — is a GET with no body at all.
    method?: "GET" | "POST" | "PATCH" | "DELETE";
    /// How to read the provider's answer. Almost everything speaks JSON; the
    /// exception is an export endpoint — a Google Doc's text — whose answer is
    /// the document itself.
    parse?: "json" | "text";
    query?: Record<string, string | undefined>;
    /// Headers for the provider rather than for Connect. Notion refuses every
    /// request that does not name an API version, and there is no other way to
    /// say so through a proxy.
    headers?: Record<string, string>;
}

/// The workspace's own OAuth client for one provider, when there is one.
///
/// Per-provider and read at call time rather than a table in code, because
/// which providers we bring our own client for is an operational fact — it
/// changes when somebody creates a client in Connect, not when we ship. Absent
/// means Pipedream's own client, which is what every connection has used so
/// far.
///
/// Named `PIPEDREAM_OAUTH_APP_<PROVIDER>`, e.g. `PIPEDREAM_OAUTH_APP_SLACK`,
/// `PIPEDREAM_OAUTH_APP_GOOGLE_CALENDAR`.
export function customOAuthAppID(provider: string): string | null {
    const key = `PIPEDREAM_OAUTH_APP_${provider.toUpperCase().replace(/-/g, "_")}`;
    return Deno.env.get(key)?.trim() || null;
}

/// One proxied call to the provider's own API. Connect injects the access token
/// and refreshes it when it has expired, which is why no token appears here.
///
/// `path` stays provider-relative, as it was under the previous broker: the base
/// comes from `PROVIDERS` rather than from a dashboard, so an adapter reads the
/// same whichever broker is underneath.
export async function proxy(
    connection: Connection,
    path: string,
    body: unknown,
    options: ProxyOptions = {},
): Promise<unknown> {
    const method = options.method ?? "POST";
    const target = new URL(path, connection.base);
    for (const [key, value] of Object.entries(options.query ?? {})) {
        if (value !== undefined) target.searchParams.set(key, value);
    }

    const url = `${connectURL(`proxy/${base64URL(target.toString())}`)}` +
        `?external_user_id=${encodeURIComponent(connection.externalUserId)}` +
        `&account_id=${encodeURIComponent(connection.id)}`;

    // Connect forwards anything prefixed `x-pd-proxy-` to the provider, with the
    // prefix stripped, and swallows everything else — its own headers carry our
    // authorization, not the provider's.
    const forwarded = Object.entries(options.headers ?? {})
        .reduce<Record<string, string>>((table, [name, value]) => {
            table[`x-pd-proxy-${name.toLowerCase()}`] = value;
            return table;
        }, {});

    const response = await fetch(url, {
        method,
        headers: { ...await connectHeaders(), ...forwarded },
        body: method === "GET" ? undefined : JSON.stringify(body),
    });

    const raw = await response.text().catch(() => "");
    let payload: unknown = null;
    try {
        payload = JSON.parse(raw);
    } catch {
        // A non-JSON answer. Fine for a text parse; null for everyone else,
        // exactly as response.json().catch(() => null) behaved before.
    }
    if (!response.ok) {
        const detail = providerDetail(payload);
        console.error(
            `connect proxy ${connection.provider}/${path} failed: ${response.status} ${detail ?? "no detail"}`,
        );
        // 401 here means the user revoked access on the provider's side; saying
        // so lets the model tell them to reconnect instead of retrying.
        const code = response.status === 401 ? "reauthorize" : "provider_error";
        // Without the provider's own words the model can only report that
        // something failed, and the person asking "why?" gets nothing back.
        const said = detail ? `: ${detail}` : ` (HTTP ${response.status})`;
        throw new ActionError(code, `${connection.provider} rejected the request${said}.`, 502, undefined, response.status);
    }
    return options.parse === "text" ? raw : payload;
}

/// However long the provider was, this is a tool result the model re-reads on
/// every later turn.
const DETAIL_LIMIT = 300;

/// What the provider said went wrong, out of whichever shape it said it in.
///
/// Every API here spells an error differently — Google nests one under `error`,
/// Jira lists `errorMessages`, Asana and GraphQL send arrays, Notion and GitHub
/// put it flat on the body — and none of them survive being thrown away. The
/// walk is generic rather than per-provider because a shape we have not seen is
/// exactly the case where the detail matters most.
export function providerDetail(payload: unknown): string | null {
    const text = firstString(payload, 0);
    if (!text) return null;
    const detail = text.replace(/\s+/g, " ").trim();
    if (!detail) return null;
    return detail.length > DETAIL_LIMIT ? `${detail.slice(0, DETAIL_LIMIT - 1)}…` : detail;
}

const DETAIL_KEYS = [
    "error_description",
    "errorMessages",
    "message",
    "error",
    "errors",
    "detail",
    "details",
    "error_message",
    "description",
    "reason",
    "status",
];

function firstString(value: unknown, depth: number): string | null {
    if (typeof value === "string") return value;
    if (depth > 4 || value === null || typeof value !== "object") return null;
    if (Array.isArray(value)) {
        for (const item of value) {
            const found = firstString(item, depth + 1);
            if (found) return found;
        }
        return null;
    }
    const table = value as Record<string, unknown>;
    for (const key of DETAIL_KEYS) {
        if (!(key in table)) continue;
        const found = firstString(table[key], depth + 1);
        if (found) return found;
    }
    return null;
}
