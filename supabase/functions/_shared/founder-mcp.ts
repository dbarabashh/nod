export const FOUNDER_ANALYTICS_PERMISSION = "founder_analytics:read";

export interface FounderMcpConfig {
  allowedOrigins: readonly string[];
  authorizationServer: string;
  resourceMetadataUri: string;
  resourceUri: string;
  supabaseAnonKey: string;
  supabaseUrl: string;
}

export type FounderReport =
  | "overview"
  | "acquisition"
  | "activation"
  | "retention"
  | "monetization"
  | "usage_cost"
  | "product_analytics"
  | "communications";

export type FounderTool =
  | "get_founder_report"
  | "list_recent_signups"
  | "find_user";

export interface FounderAuditMetadata {
  identity_query_length?: number;
  include_identity?: boolean;
  returned_row_count: number;
}

export class FounderMcpRequestTimeoutError extends Error {}

function parseHttpsUrl(value: string): URL | null {
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" || url.username || url.password || url.search ||
      url.hash
    ) return null;
    return url;
  } catch {
    return null;
  }
}

function parseSupabaseUrl(value: string): URL | null {
  try {
    const url = new URL(value);
    const local = url.hostname === "localhost" ||
      url.hostname === "127.0.0.1" ||
      url.hostname === "kong";
    if (
      (url.protocol !== "https:" && !(local && url.protocol === "http:")) ||
      url.username || url.password || url.search || url.hash
    ) return null;
    return url;
  } catch {
    return null;
  }
}

export function loadFounderMcpConfig(
  read: (name: string) => string | undefined = (name) => Deno.env.get(name),
): FounderMcpConfig | null {
  const resourceUri = read("FOUNDER_MCP_RESOURCE_URI")?.trim() ?? "";
  const supabaseUrlValue = read("SUPABASE_URL")?.trim() ?? "";
  const supabaseAnonKey = read("SUPABASE_ANON_KEY")?.trim() ?? "";
  const resource = parseHttpsUrl(resourceUri);
  const supabase = parseSupabaseUrl(supabaseUrlValue);
  if (
    !resource || resource.pathname !== "/mcp" || !supabase || !supabaseAnonKey
  ) {
    return null;
  }

  const configuredAuthorizationServer = read("MCP_AUTHORIZATION_SERVER")
    ?.trim();
  const authorizationServer = configuredAuthorizationServer
    ? parseHttpsUrl(configuredAuthorizationServer)
    : new URL("/auth/v1", supabase);
  if (!authorizationServer) return null;

  const allowedOriginsRaw = read("FOUNDER_MCP_ALLOWED_ORIGINS")?.trim() ?? "";
  const allowedOrigins: string[] = [];
  for (
    const candidate of allowedOriginsRaw.split(",").map((item) => item.trim())
      .filter(Boolean)
  ) {
    const origin = parseHttpsUrl(candidate);
    if (!origin || origin.origin !== candidate || origin.pathname !== "/") {
      return null;
    }
    allowedOrigins.push(origin.origin);
  }

  return {
    allowedOrigins: [...new Set(allowedOrigins)],
    authorizationServer: authorizationServer.toString().replace(/\/$/, ""),
    resourceMetadataUri: new URL(
      "/.well-known/oauth-protected-resource",
      resource,
    ).toString(),
    resourceUri: resource.toString(),
    supabaseAnonKey,
    supabaseUrl: supabase.toString().replace(/\/$/, ""),
  };
}

export function founderRequestOriginAllowed(
  req: Request,
  allowedOrigins: readonly string[],
): boolean {
  const origin = req.headers.get("Origin");
  return origin === null || allowedOrigins.includes(origin);
}

export function founderCorsHeaders(
  req: Request,
  allowedOrigins: readonly string[],
): Record<string, string> {
  const origin = req.headers.get("Origin");
  if (!origin || !allowedOrigins.includes(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers":
      "authorization, content-type, mcp-protocol-version, mcp-session-id",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Expose-Headers":
      "mcp-session-id, retry-after, www-authenticate",
    "Vary": "Origin",
  };
}

function arrayLength(value: unknown, key: string): number {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return 0;
  }
  const rows = (value as Record<string, unknown>)[key];
  return Array.isArray(rows) ? rows.length : 0;
}

export function founderAuditMetadata(
  tool: FounderTool,
  data: unknown,
  options: { includeIdentity?: boolean; identityQueryLength?: number } = {},
): FounderAuditMetadata {
  const metadata: FounderAuditMetadata = {
    returned_row_count: tool === "list_recent_signups"
      ? arrayLength(data, "signups")
      : tool === "find_user"
      ? arrayLength(data, "matches")
      : data === null || data === undefined
      ? 0
      : 1,
  };
  if (tool === "list_recent_signups") {
    metadata.include_identity = options.includeIdentity === true;
  }
  if (tool === "find_user") {
    metadata.identity_query_length = Math.max(
      0,
      Math.min(120, options.identityQueryLength ?? 0),
    );
  }
  return metadata;
}

function compact(value: unknown, depth: number): unknown {
  if (typeof value === "string") return value.slice(0, 2_000);
  if (typeof value !== "object" || value === null) return value;
  if (depth >= 6) return "[depth limited]";
  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => compact(item, depth + 1));
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [key, compact(item, depth + 1)]),
  );
}

export function boundedMcpResult(
  value: unknown,
  maxCharacters = 60_000,
): { value: unknown; truncated: boolean } {
  const serialized = JSON.stringify(value);
  if (serialized.length <= maxCharacters) return { value, truncated: false };

  const compacted = compact(value, 0);
  const compactedSerialized = JSON.stringify(compacted);
  if (compactedSerialized.length <= maxCharacters) {
    return { value: compacted, truncated: true };
  }

  const topLevelKeys =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? Object.keys(value).slice(0, 50)
      : [];
  return {
    value: {
      truncated: true,
      message:
        "The report exceeded the safe response size. Request a narrower window or report.",
      top_level_keys: topLevelKeys,
    },
    truncated: true,
  };
}

export function normalizeFounderGatewayResult(
  value: unknown,
  maxCharacters = 60_000,
): { result: unknown; truncated: boolean } {
  let result = value;
  let databaseTruncated = false;
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    if ("result" in record && typeof record.truncated === "boolean") {
      result = record.result;
      databaseTruncated = record.truncated;
    } else if (
      record.truncated === true && typeof record.message === "string"
    ) {
      result = { message: record.message };
      databaseTruncated = true;
    }
  }

  const bounded = boundedMcpResult(
    result,
    Math.max(1_000, maxCharacters - 1_000),
  );
  const output = {
    result: bounded.value,
    truncated: databaseTruncated || bounded.truncated,
  };
  if (JSON.stringify(output).length <= maxCharacters) return output;
  return {
    result: {
      message:
        "The report exceeded the safe response size. Request a narrower window or report.",
    },
    truncated: true,
  };
}

export async function boundedFounderMcpRequest(
  req: Request,
  maxBytes = 65_536,
  timeoutMs = 5_000,
): Promise<Request | null> {
  if (req.body === null) return req;
  const declaredLength = req.headers.get("Content-Length");
  if (declaredLength !== null) {
    const parsedLength = Number(declaredLength);
    if (
      !Number.isSafeInteger(parsedLength) || parsedLength < 0 ||
      parsedLength > maxBytes
    ) {
      return null;
    }
  }

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let timedOut = false;
  const timeoutId = setTimeout(() => {
    timedOut = true;
    void reader.cancel("request body timeout");
  }, timeoutMs);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    clearTimeout(timeoutId);
  }
  if (timedOut) {
    throw new FounderMcpRequestTimeoutError("request body timed out");
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new Request(req.url, {
    body,
    headers: req.headers,
    method: req.method,
    signal: req.signal,
  });
}

export async function withFounderMcpTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  onTimeout: () => void = () => {},
): Promise<{ timedOut: false; value: T } | { timedOut: true }> {
  let timeoutId: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<{ timedOut: true }>((resolve) => {
    timeoutId = setTimeout(() => {
      resolve({ timedOut: true });
      onTimeout();
    }, timeoutMs);
  });
  const result = await Promise.race([
    operation.then((value) => ({ timedOut: false as const, value })),
    timeout,
  ]);
  if (timeoutId !== undefined) clearTimeout(timeoutId);
  return result;
}
