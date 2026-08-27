import type { ConnectorIdentity } from "./connector-auth.ts";

export const FOUNDER_ANALYTICS_PERMISSION = "founder_analytics:read";
export const FOUNDER_ANALYTICS_EMAILS = [
  "dmytro@hellonod.app",
  "vlad@hellonod.app",
] as const;

export type FounderReport =
  | "overview"
  | "acquisition"
  | "activation"
  | "retention"
  | "monetization"
  | "usage_cost"
  | "product_analytics"
  | "communications";

export function founderIdentityAllowed(identity: ConnectorIdentity): boolean {
  const userEmail = identity.user.email?.trim().toLowerCase();
  const claimEmail = identity.claims.email?.trim().toLowerCase();
  return Boolean(
    userEmail &&
      claimEmail === userEmail &&
      FOUNDER_ANALYTICS_EMAILS.includes(
        userEmail as typeof FOUNDER_ANALYTICS_EMAILS[number],
      ),
  );
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
