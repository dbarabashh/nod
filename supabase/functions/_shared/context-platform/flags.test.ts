import { assertEquals } from "jsr:@std/assert@1.0.14";
import { briefingsV1Enabled, ingestionV2Enabled } from "./flags.ts";

function withEnv(vars: Record<string, string>, body: () => void) {
  for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
  try {
    body();
  } finally {
    for (const k of Object.keys(vars)) Deno.env.delete(k);
  }
}

Deno.test("unset flag reads as off", () => {
  assertEquals(ingestionV2Enabled(), false);
});

Deno.test('explicit "true" turns a flag on', () => {
  withEnv({ BRIEFINGS_V1: "true" }, () => {
    assertEquals(briefingsV1Enabled(), true);
  });
});

Deno.test('anything other than the literal "true" stays off', () => {
  withEnv({ INGESTION_V2: "1" }, () => {
    assertEquals(ingestionV2Enabled(), false);
  });
});
