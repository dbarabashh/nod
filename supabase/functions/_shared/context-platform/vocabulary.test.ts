import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
  CONTEXT_RELATIONS,
  linkActionFor,
  SOURCE_OBJECT_TYPES,
} from "./vocabulary.ts";

Deno.test("confidence >= 0.90 auto-links", () => {
  assertEquals(linkActionFor(0.9), "auto_edge");
  assertEquals(linkActionFor(0.95), "auto_edge");
});

Deno.test("confidence 0.70-0.89 is a candidate only", () => {
  assertEquals(linkActionFor(0.7), "candidate_edge");
  assertEquals(linkActionFor(0.89), "candidate_edge");
});

Deno.test("confidence below 0.70 is discarded", () => {
  assertEquals(linkActionFor(0.69), "discard");
  assertEquals(linkActionFor(0), "discard");
});

Deno.test("vocabularies match the plan's counts", () => {
  assertEquals(SOURCE_OBJECT_TYPES.size, 10);
  assertEquals(CONTEXT_RELATIONS.size, 13);
});
