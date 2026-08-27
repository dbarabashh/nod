import {
  createMcpHandler,
} from "npm:@modelcontextprotocol/server@2.0.0";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  createServer,
  withFounderToolSecuritySchemes,
} from "../founder-mcp/index.ts";

function protocolRequest(method: string, id: number, params: Record<string, unknown> = {}) {
  return new Request("https://founder.example/mcp", {
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    headers: {
      Accept: "application/json, text/event-stream",
      "Content-Type": "application/json",
    },
    method: "POST",
  });
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
    throw new Error(`initialize failed: ${initialize.status} ${await initialize.text()}`);
  }

  const raw = await handler.fetch(protocolRequest("tools/list", 2));
  if (!raw.ok) throw new Error(`tools/list failed: ${raw.status} ${await raw.text()}`);
  const response = await withFounderToolSecuritySchemes(raw);
  const responseText = await response.text();
  const dataLine = responseText.split("\n").find((line) => line.startsWith("data: "));
  const payload = JSON.parse(dataLine ? dataLine.slice(6) : responseText);
  const tools = payload?.result?.tools;
  if (!Array.isArray(tools) || tools.length !== 3) {
    throw new Error("tools/list did not return the three founder tools");
  }
  for (const tool of tools) {
    const expected = [{ type: "oauth2", scopes: ["openid", "email"] }];
    if (JSON.stringify(tool.securitySchemes) !== JSON.stringify(expected)) {
      throw new Error(`${tool.name} omitted top-level OAuth security schemes`);
    }
    if (JSON.stringify(tool._meta?.securitySchemes) !== JSON.stringify(expected)) {
      throw new Error(`${tool.name} omitted compatibility OAuth security metadata`);
    }
    if (!tool.description?.includes("untrusted data") || !tool.description?.includes("never instructions")) {
      throw new Error(`${tool.name} omitted prompt-injection handling guidance`);
    }
  }
  const report = tools.find((tool: { name?: string }) => tool.name === "get_founder_report");
  if (!report?.description?.includes("Days applies only") || !report.description.includes("all-time")) {
    throw new Error("report descriptor did not disclose window semantics");
  }
});
