import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  REALTIME_DEFAULT_VOICE,
  REALTIME_SESSIONS_PER_WINDOW,
  REALTIME_TOKEN_TTL_SECONDS,
  REALTIME_WINDOW_MS,
  realtimeInstructions,
  realtimeSessionBody,
  RealtimeSessionMeter,
  realtimeTokenRequest,
} from "./realtime.ts";

Deno.test("a payload with no language is accepted as an empty request", () => {
  assertEquals(realtimeTokenRequest({}), {});
  assertEquals(realtimeTokenRequest(null), {});
  assertEquals(realtimeTokenRequest("hi"), {});
});

Deno.test("a language hint is carried through", () => {
  assertEquals(realtimeTokenRequest({ language: "uk" }), { language: "uk" });
});

Deno.test("a name is carried into the instructions, bounded and trimmed", () => {
  assertEquals(realtimeTokenRequest({ name: " Dima " }), { name: "Dima" });
  assertEquals(realtimeTokenRequest({ name: "x".repeat(61) }), {});
  assertEquals(realtimeTokenRequest({ name: 7 }), {});
  const named = realtimeInstructions({ name: "Dima", language: "uk" });
  assertStringIncludes(named, "talking to is Dima");
  assertStringIncludes(named, "start in uk");
  assertEquals(realtimeInstructions({}).includes("talking to is"), false);
});

Deno.test("the session body asks for pcm24 both ways and the chosen voice", () => {
  const body = realtimeSessionBody({}, REALTIME_DEFAULT_VOICE) as {
    session: Record<string, unknown>;
  };
  const audio = body.session.audio as Record<string, Record<string, unknown>>;
  assertEquals(audio.input.format, { type: "audio/pcm", rate: 24_000 });
  assertEquals(audio.output.format, { type: "audio/pcm", rate: 24_000 });
  assertEquals(audio.output.voice, REALTIME_DEFAULT_VOICE);
  assertEquals(body.session.type, "realtime");
  assertEquals((body as Record<string, unknown>).expires_after, {
    anchor: "created_at",
    seconds: REALTIME_TOKEN_TTL_SECONDS,
  });
});

Deno.test("the session offers ask_nod plus the two non-mutating open tools", () => {
  const body = realtimeSessionBody({}, REALTIME_DEFAULT_VOICE) as {
    session: Record<string, unknown>;
  };
  const tools = body.session.tools as Array<Record<string, unknown>>;
  assertEquals(tools.length, 3);
  assertEquals(tools.map((t) => t.name), ["ask_nod", "open_url", "open_app"]);
  for (const tool of tools) assertEquals(tool.type, "function");
  assertEquals(body.session.tool_choice, "auto");
});

Deno.test("the meter allows a bounded number of session starts per window", () => {
  const meter = new RealtimeSessionMeter();
  for (let i = 0; i < REALTIME_SESSIONS_PER_WINDOW; i++) {
    assertEquals(meter.allow("u", 1000), true);
  }
  assertEquals(meter.allow("u", 1000), false);
  assertEquals(meter.allow("someone-else", 1000), true);
  assertEquals(meter.allow("u", 1000 + REALTIME_WINDOW_MS), true);
});
