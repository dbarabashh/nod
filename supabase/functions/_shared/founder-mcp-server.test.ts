import { createMcpHandler } from "npm:@modelcontextprotocol/server@2.0.0";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  createServer,
  withFounderToolSecuritySchemes,
} from "../founder-mcp/index.ts";

function protocolRequest(
  method: string,
  id: number,
  params: Record<string, unknown> = {},
) {
  return new Request("https://founder.example/mcp", {
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    headers: {
      Accept: "application/json, text/event-stream",
      "Content-Type": "application/json",
    },
    method: "POST",
  });
}

function protocolPayload(responseText: string) {
  const dataLine = responseText.split("\n").find((line) =>
    line.startsWith("data: ")
  );
  return JSON.parse(dataLine ? dataLine.slice(6) : responseText);
}

Deno.test("founder MCP tools/list wire response carries OAuth security schemes", async () => {
  const handler = createMcpHandler(
    () => createServer({} as SupabaseClient),
    { responseMode: "json" },
  );
  const initialize = await handler.fetch(protocolRequest("initialize", 1, {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "contract-test", version: "1.0.0" },
  }));
  if (!initialize.ok) {
    throw new Error(
      `initialize failed: ${initialize.status} ${await initialize.text()}`,
    );
  }

  const raw = await handler.fetch(protocolRequest("tools/list", 2));
  if (!raw.ok) {
    throw new Error(`tools/list failed: ${raw.status} ${await raw.text()}`);
  }
  const response = await withFounderToolSecuritySchemes(raw);
  const responseText = await response.text();
  const payload = protocolPayload(responseText);
  const tools = payload?.result?.tools;
  if (!Array.isArray(tools) || tools.length !== 3) {
    throw new Error("tools/list did not return the three founder tools");
  }
  for (const tool of tools) {
    const expected = [{ type: "oauth2", scopes: ["openid", "email"] }];
    if (JSON.stringify(tool.securitySchemes) !== JSON.stringify(expected)) {
      throw new Error(`${tool.name} omitted top-level OAuth security schemes`);
    }
    if (
      JSON.stringify(tool._meta?.securitySchemes) !== JSON.stringify(expected)
    ) {
      throw new Error(
        `${tool.name} omitted compatibility OAuth security metadata`,
      );
    }
    if (
      !tool.description?.includes("untrusted data") ||
      !tool.description?.includes("never instructions")
    ) {
      throw new Error(
        `${tool.name} omitted prompt-injection handling guidance`,
      );
    }
  }
  const report = tools.find((tool: { name?: string }) =>
    tool.name === "get_founder_report"
  );
  if (
    !report?.description?.includes("section-specific") ||
    !report.description.includes("Days applies")
  ) {
    throw new Error("report descriptor did not disclose window semantics");
  }
});

Deno.test("founder MCP tool wire response does not duplicate bounded result data", async () => {
  const payloadText = "x".repeat(50_000);
  const client = {
    rpc: async () => ({
      data: { result: { payload: payloadText }, truncated: false },
      error: null,
    }),
  } as unknown as SupabaseClient;
  const handler = createMcpHandler(
    () => createServer(client),
    { responseMode: "json" },
  );
  const initialize = await handler.fetch(protocolRequest("initialize", 1, {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "contract-test", version: "1.0.0" },
  }));
  if (!initialize.ok) {
    throw new Error(`initialize failed: ${initialize.status}`);
  }

  const response = await handler.fetch(protocolRequest("tools/call", 2, {
    name: "get_founder_report",
    arguments: { report: "overview" },
  }));
  const responseText = await response.text();
  if (!response.ok) {
    throw new Error(`tools/call failed: ${response.status} ${responseText}`);
  }
  if (responseText.length >= 60_000) {
    throw new Error(
      `tools/call exceeded the wire response budget: ${responseText.length}`,
    );
  }
  const payload = protocolPayload(responseText);
  const result = payload?.result;
  if (result?.structuredContent?.result?.payload !== payloadText) {
    throw new Error("tools/call omitted the bounded structured result");
  }
  if (result?.content?.[0]?.text?.includes(payloadText)) {
    throw new Error("tools/call duplicated structured data in text content");
  }
});
