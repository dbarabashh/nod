import {
  boundedFounderMcpRequest,
  boundedMcpResult,
  founderAuditMetadata,
  founderCorsHeaders,
  founderRequestOriginAllowed,
  loadFounderMcpConfig,
  normalizeFounderGatewayResult,
  withFounderMcpTimeout,
} from "./founder-mcp.ts";

function config(values: Record<string, string>): ReturnType<typeof loadFounderMcpConfig> {
  return loadFounderMcpConfig((name) => values[name]);
}

Deno.test("founder MCP configuration fails closed", () => {
  const valid = {
    FOUNDER_MCP_RESOURCE_URI: "https://founder.example/mcp",
    SUPABASE_URL: "https://project.supabase.co",
    SUPABASE_ANON_KEY: "anon-key",
  };
  if (config(valid) === null) throw new Error("expected explicit configuration to load");
  if (config({ ...valid, FOUNDER_MCP_RESOURCE_URI: "" }) !== null) {
    throw new Error("missing resource URI must fail closed");
  }
  if (config({ ...valid, FOUNDER_MCP_RESOURCE_URI: "http://founder.example/mcp" }) !== null) {
    throw new Error("insecure resource URI must fail closed");
  }
  if (config({ ...valid, FOUNDER_MCP_RESOURCE_URI: "https://founder.example/other" }) !== null) {
    throw new Error("unexpected resource path must fail closed");
  }
  if (config({ ...valid, SUPABASE_ANON_KEY: "" }) !== null) {
    throw new Error("missing Supabase key must fail closed");
  }
});

Deno.test("founder MCP CORS uses an exact configured origin", () => {
  const req = new Request("https://founder.example/mcp", {
    headers: { Origin: "https://chatgpt.com" },
  });
  const origins = ["https://chatgpt.com"];
  if (!founderRequestOriginAllowed(req, origins)) throw new Error("configured origin was rejected");
  if (founderCorsHeaders(req, origins)["Access-Control-Allow-Origin"] !== "https://chatgpt.com") {
    throw new Error("configured origin was not echoed");
  }
  const attacker = new Request("https://founder.example/mcp", {
    headers: { Origin: "https://attacker.example" },
  });
  if (founderRequestOriginAllowed(attacker, origins)) throw new Error("unlisted HTTPS origin was accepted");
  if (Object.keys(founderCorsHeaders(attacker, origins)).length !== 0) {
    throw new Error("unlisted origin received CORS headers");
  }
});

Deno.test("founder MCP audit metadata never includes identity search text", () => {
  const recent = founderAuditMetadata(
    "list_recent_signups",
    { signups: [{}, {}] },
    { includeIdentity: true },
  );
  if (!recent.include_identity || recent.returned_row_count !== 2) {
    throw new Error("recent-signup audit metadata is incomplete");
  }
  const query = "private-person@example.com";
  const found = founderAuditMetadata(
    "find_user",
    { matches: [{}] },
    { identityQueryLength: query.length },
  );
  const serialized = JSON.stringify(found);
  if (found.identity_query_length !== query.length || found.returned_row_count !== 1) {
    throw new Error("identity-query audit metadata is incomplete");
  }
  if (serialized.includes(query)) throw new Error("audit metadata retained the identity query");
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

Deno.test("founder MCP preserves database truncation in the final envelope", () => {
  const modern = normalizeFounderGatewayResult({
    result: { message: "narrow the report" },
    truncated: true,
  });
  if (!modern.truncated || "result" in (modern.result as Record<string, unknown>)) {
    throw new Error("database envelope was double wrapped or lost truncation");
  }
  const legacy = normalizeFounderGatewayResult({
    truncated: true,
    message: "narrow the report",
  });
  if (!legacy.truncated || JSON.stringify(legacy).length > 60_000) {
    throw new Error("legacy database truncation was not propagated safely");
  }
});

Deno.test("founder MCP bounds declared and chunked request bodies", async () => {
  const accepted = await boundedFounderMcpRequest(new Request("https://founder.example/mcp", {
    body: "1234",
    method: "POST",
  }), 4);
  if (accepted === null || await accepted.text() !== "1234") {
    throw new Error("bounded request was not preserved");
  }

  const declared = await boundedFounderMcpRequest(new Request("https://founder.example/mcp", {
    body: "12345",
    headers: { "Content-Length": "5" },
    method: "POST",
  }), 4);
  if (declared !== null) throw new Error("oversized declared body was accepted");

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("123"));
      controller.enqueue(new TextEncoder().encode("45"));
      controller.close();
    },
  });
  const chunked = await boundedFounderMcpRequest(new Request("https://founder.example/mcp", {
    body: stream,
    method: "POST",
  }), 4);
  if (chunked !== null) throw new Error("oversized chunked body was accepted");
});

Deno.test("founder MCP applies an execution timeout", async () => {
  const completed = await withFounderMcpTimeout(Promise.resolve("ok"), 100);
  if (completed.timedOut || completed.value !== "ok") {
    throw new Error("completed work timed out");
  }
  const timedOut = await withFounderMcpTimeout(
    new Promise<string>(() => {}),
    1,
  );
  if (!timedOut.timedOut) throw new Error("stalled work did not time out");
});
