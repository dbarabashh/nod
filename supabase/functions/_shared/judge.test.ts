import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { JUDGE_MAX_BYTES, JUDGE_MAX_QUESTIONS, judgeRefusal } from "./judge.ts";

const noul = { type: "noul", instructions: "Does `question` ask about the user's own work?" };

Deno.test("a state and typed questions pass", () => {
    assertEquals(judgeRefusal({ state: { question: "що я робив" }, questions: { own_work: noul } }), null);
    assertEquals(judgeRefusal({ state: "plain text", questions: { own_work: noul } }), null);
});

Deno.test("anything that is not a judge payload is refused", () => {
    assertEquals(judgeRefusal(null)?.status, 400);
    assertEquals(judgeRefusal({ state: 7, questions: { own_work: noul } })?.error, "judge_payload_invalid");
    assertEquals(judgeRefusal({ state: "x", questions: [] })?.error, "judge_payload_invalid");
    assertEquals(judgeRefusal({ state: "x", questions: {} })?.error, "judge_question_count");
});

Deno.test("a question needs a known type and instructions", () => {
    assertEquals(judgeRefusal({ state: "x", questions: { q: { type: "essay", instructions: "?" } } })?.error, "judge_question_invalid");
    assertEquals(judgeRefusal({ state: "x", questions: { q: { type: "noul" } } })?.error, "judge_question_invalid");
});

Deno.test("the relay is bounded", () => {
    const many = Object.fromEntries(Array.from({ length: JUDGE_MAX_QUESTIONS + 1 }, (_, i) => [`q${i}`, noul]));
    assertEquals(judgeRefusal({ state: "x", questions: many })?.error, "judge_question_count");
    assertEquals(judgeRefusal({ state: "x".repeat(JUDGE_MAX_BYTES), questions: { q: noul } })?.status, 413);
});
