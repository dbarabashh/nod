import {
  type ConnectorClaims,
  connectorClaimsValid,
  decodeConnectorClaims,
  oauthChallenge,
} from "./connector-auth.ts";

const issuer = "https://preview.supabase.co/auth/v1";
const resource = "https://preview.supabase.co/functions/v1/mcp";
const userId = "3ac91de5-9f85-4147-9f3a-11904b896dc7";
const now = 1_786_010_400;

function claims(overrides: Partial<ConnectorClaims> = {}): ConnectorClaims {
  return {
    aud: resource,
    client_id: "chatgpt-client",
    exp: now + 3600,
    iss: issuer,
    nod_permissions: ["meetings:read"],
    role: "mcp_connector",
    sub: userId,
    ...overrides,
  };
}

Deno.test("accepts a resource-bound connector token", () => {
  if (!connectorClaimsValid(claims(), userId, resource, issuer, now)) {
    throw new Error("expected valid claims");
  }
});

Deno.test("accepts an independently permissioned founder token", () => {
  const founderResource = "https://nod-founder-dashboard.vercel.app/mcp";
  const founderClaims = claims({
    aud: founderResource,
    nod_permissions: ["founder_analytics:read"],
  });
  if (
    !connectorClaimsValid(
      founderClaims,
      userId,
      founderResource,
      issuer,
      now,
      "founder_analytics:read",
    )
  ) {
    throw new Error("expected valid founder claims");
  }
  if (
    connectorClaimsValid(
      claims({ aud: founderResource }),
      userId,
      founderResource,
      issuer,
      now,
      "founder_analytics:read",
    )
  ) {
    throw new Error(
      "meeting permission must not imply founder analytics access",
    );
  }
  if (
    connectorClaimsValid(
      founderClaims,
      userId,
      resource,
      issuer,
      now,
      "meetings:read",
    )
  ) {
    throw new Error("founder permission must not imply meeting access");
  }
});

Deno.test("rejects expired, wrong issuer, audience, permission, and role claims", () => {
  const invalid = [
    claims({ exp: now }),
    claims({ iss: "https://attacker.example/auth/v1" }),
    claims({ aud: "https://attacker.example/mcp" }),
    claims({ nod_permissions: ["profile:read"] }),
    claims({ role: "authenticated" }),
    claims({ client_id: "" }),
    claims({ sub: "another-user" }),
  ];
  if (
    invalid.some((value) =>
      connectorClaimsValid(value, userId, resource, issuer, now)
    )
  ) {
    throw new Error("expected every invalid claim set to be rejected");
  }
});

Deno.test("rejects malformed bearer payloads", () => {
  if (decodeConnectorClaims("not-a-jwt") !== null) {
    throw new Error("expected malformed token rejection");
  }
  if (decodeConnectorClaims("a.%%%.b") !== null) {
    throw new Error("expected invalid base64 rejection");
  }
});

Deno.test("advertises protected-resource metadata in bearer challenges", () => {
  const challenge = oauthChallenge(
    "https://hellonod.app/.well-known/oauth-protected-resource",
    "invalid_token",
  );
  if (
    !challenge.includes(
      'resource_metadata="https://hellonod.app/.well-known/oauth-protected-resource"',
    )
  ) {
    throw new Error("missing resource metadata URI");
  }
  if (!challenge.includes('error="invalid_token"')) {
    throw new Error("missing OAuth error");
  }
});
