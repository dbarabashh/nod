import type { User } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import type { ConnectorIdentity } from "./connector-auth.ts";
import { boundedMcpResult, founderIdentityAllowed } from "./founder-mcp.ts";

function identity(email: string, claimEmail = email): ConnectorIdentity {
  return {
    claims: { email: claimEmail },
    token: "token",
    user: { id: crypto.randomUUID(), email } as User,
  };
}

Deno.test("founder analytics allowlist is exact", () => {
  if (!founderIdentityAllowed(identity("vlad@hellonod.app"))) {
    throw new Error("Vlad should be allowlisted");
  }
  if (!founderIdentityAllowed(identity("DMYTRO@HELLONOD.APP"))) {
    throw new Error("Dmytro should be allowlisted case-insensitively");
  }
  if (founderIdentityAllowed(identity("viktoriia@hellonod.app"))) {
    throw new Error("Viktoriia has dashboard access, not founder MCP access");
  }
  if (
    founderIdentityAllowed(
      identity("vlad@hellonod.app", "attacker@example.com"),
    )
  ) {
    throw new Error("verified and claimed emails must match");
  }
});

Deno.test("founder MCP results stay bounded", () => {
  const oversized = {
    rows: Array.from({ length: 500 }, (_, index) => ({
      index,
      text: "x".repeat(5_000),
    })),
  };
  const result = boundedMcpResult(oversized, 10_000);
  if (!result.truncated) {
    throw new Error("expected oversized output to be bounded");
  }
  if (JSON.stringify(result.value).length > 10_000) {
    throw new Error("bounded response still exceeds the maximum");
  }
});

Deno.test("founder MCP keeps normal responses intact", () => {
  const original = { rows: [{ value: 1 }] };
  const result = boundedMcpResult(original);
  if (result.truncated || result.value !== original) {
    throw new Error("small output should not be rewritten");
  }
});
