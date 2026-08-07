const LEGACY_SUNSET = Deno.env.get("LEGACY_MCP_PAT_DISABLE_AFTER") ?? "";
export const CONNECTOR_MIGRATION_URL = Deno.env.get("MCP_MIGRATION_URL") ??
  "https://hellonod.app/connectors";

export function legacyConnectorHeaders(
  sunset = LEGACY_SUNSET,
): Record<string, string> {
  const headers: Record<string, string> = {
    Deprecation: "true",
    Link: `<${CONNECTOR_MIGRATION_URL}>; rel="deprecation"`,
  };
  if (sunset) {
    const date = new Date(sunset);
    if (!Number.isNaN(date.getTime())) headers.Sunset = date.toUTCString();
  }
  return headers;
}

export function legacyConnectorExpired(
  now = Date.now(),
  sunset = LEGACY_SUNSET,
): boolean {
  if (!sunset) return false;
  const date = new Date(sunset);
  return !Number.isNaN(date.getTime()) && date.getTime() <= now;
}
