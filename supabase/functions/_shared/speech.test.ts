import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  DEFAULT_VOICE,
  isSpeechRefusal,
  looksAlreadySpoken,
  scriptPrompt,
  SPEECH_CALLS_PER_WINDOW,
  SPEECH_MAX_CHARS,
  SPEECH_WINDOW_MS,
  speechInstructions,
  speaksAsWritten,
  SpeechMeter,
  speechChunks,
  speechRequest,
  TTS_MODEL,
  ttsBody,
  ttsCostUsd,
} from "./speech.ts";

function request(payload: unknown) {
  const parsed = speechRequest(payload);
  if (isSpeechRefusal(parsed)) throw new Error(parsed.error);
  return parsed;
}

Deno.test("a short line in an app language is accepted", () => {
  assertEquals(
    request({
      text: " Your ten-thirty is with Ana. ",
      language: "en",
      purpose: "answer",
      question: "what's next",
    }),
    {
      text: "Your ten-thirty is with Ana.",
      language: "en",
      purpose: "answer",
      question: "what's next",
      verbatim: false,
      stream: false,
    },
  );
});

Deno.test("a caller may vouch for its own line and ask for the clips as they come", () => {
  const vouched = request({ text: "On it.", language: "en", purpose: "acknowledgement", verbatim: true, stream: true });
  assertEquals(vouched.verbatim, true);
  assertEquals(vouched.stream, true);
  assertEquals(speaksAsWritten(vouched), true);
  const plain = request({ text: "On it.", language: "en", purpose: "acknowledgement" });
  assertEquals(speaksAsWritten(plain), false);
  assertEquals(request({ text: "On it.", language: "en", purpose: "answer", verbatim: "yes" }).verbatim, false);
  const page = request({ text: "x".repeat(400), language: "en", purpose: "narration", verbatim: true });
  assertEquals(speaksAsWritten(page), false);
});

Deno.test("the first sentence is synthesised on its own, the rest together", () => {
  assertEquals(
    speechChunks("Your morning was the dashboard. Then you were in VS Code for an hour. Ryan's call is worth keeping in mind."),
    ["Your morning was the dashboard.", "Then you were in VS Code for an hour. Ryan's call is worth keeping in mind."],
  );
  assertEquals(speechChunks("Your ten-thirty is with Ana."), ["Your ten-thirty is with Ana."]);
  assertEquals(speechChunks("Це на Владі, не на тобі! Далі календар."), ["Це на Владі, не на тобі!", "Далі календар."]);
  assertEquals(speechChunks("Ana said \"no.\" Then left."), ["Ana said \"no.\"", "Then left."]);
  assertEquals(speechChunks("Dr. Smith is in at ten. Then Ana."), ["Dr. Smith is in at ten. Then Ana."]);
  assertEquals(speechChunks("Okay. Your morning was the dashboard."), ["Okay. Your morning was the dashboard."]);
});

Deno.test("an unnamed purpose is an answer; anything but an acknowledgement is too", () => {
  assertEquals(request({ text: "hi", language: "en" }).purpose, "answer");
  assertEquals(
    request({ text: "hi", language: "en", purpose: "poem" }).purpose,
    "answer",
  );
  assertEquals(
    request({ text: "hi", language: "en", purpose: "acknowledgement" }).purpose,
    "acknowledgement",
  );
});

Deno.test("only the app's languages may be named", () => {
  assertEquals(speechRequest({ text: "hi", language: "xx" }), {
    error: "invalid_language",
    status: 400,
  });
  assertEquals(speechRequest({ text: "hi" }), {
    error: "invalid_language",
    status: 400,
  });
});

Deno.test("a document is not a line", () => {
  assertEquals(
    speechRequest({ text: "a".repeat(SPEECH_MAX_CHARS + 1), language: "en" }),
    {
      error: "speech_too_long",
      status: 413,
    },
  );
  assertEquals(speechRequest({ text: "   ", language: "en" }), {
    error: "invalid_text",
    status: 400,
  });
  assertEquals(speechRequest(null), { error: "invalid_payload", status: 400 });
});

Deno.test("the script prompt is told the language and never handed the text to read", () => {
  const prompt = scriptPrompt(
    request({
      text: "**10:30** with Ana",
      language: "uk",
      purpose: "answer",
      question: "коли зустріч",
    }),
  );
  assertStringIncludes(prompt.system, "Ukrainian");
  assertStringIncludes(prompt.system, "never list");
  assertStringIncludes(prompt.system, "friend");
  assertStringIncludes(prompt.user, "коли зустріч");
  const ack = scriptPrompt(
    request({
      text: "коли зустріч",
      language: "uk",
      purpose: "acknowledgement",
    }),
  );
  assertStringIncludes(ack.system, "Do not answer the question");
});

Deno.test("narration is said in the same voice as an answer, not a separate character", () => {
  assertEquals(speechInstructions("narration"), speechInstructions("answer"));
  assertStringIncludes(speechInstructions("narration"), "one specific person");
});

Deno.test("the acknowledgement and the answer share one voice identity but differ in energy", () => {
  const ack = speechInstructions("acknowledgement");
  const answer = speechInstructions("answer");
  assertStringIncludes(ack, "one specific person");
  assertStringIncludes(answer, "one specific person");
  assertStringIncludes(ack, "even and steady");
  assertStringIncludes(answer, "even and steady");
  assertStringIncludes(ack, "quick, warm aside");
  assertStringIncludes(answer, "unhurried");
});

Deno.test("the tts body asks for an mp3 with instructions and the chosen voice", () => {
  const body = ttsBody("Your ten-thirty is with Ana.", DEFAULT_VOICE, "answer");
  assertEquals(body.model, TTS_MODEL);
  assertEquals(body.voice, DEFAULT_VOICE);
  assertEquals(body.response_format, "mp3");
  assertStringIncludes(body.instructions as string, "friend");
});

Deno.test("cost follows length", () => {
  assertEquals(ttsCostUsd(1000), 0.015);
});

Deno.test("a short flat line skips the rephrase step; markdown or length does not", () => {
  assertEquals(looksAlreadySpoken("It's Tuesday."), true);
  assertEquals(looksAlreadySpoken("You have three meetings left today."), true);
  assertEquals(looksAlreadySpoken("Your **10:30** is with Ana."), false);
  assertEquals(looksAlreadySpoken("- one\n- two"), false);
  assertEquals(looksAlreadySpoken("1. First step"), false);
  assertEquals(looksAlreadySpoken("a".repeat(221)), false);
  assertEquals(
    looksAlreadySpoken("Check https://cal.com/x for the invite."),
    false,
  );
  assertEquals(looksAlreadySpoken("It's ticket PROJ-4821."), false);
  assertEquals(
    looksAlreadySpoken("Open /Users/dima/notes/plan.md for it."),
    false,
  );
  assertEquals(looksAlreadySpoken("It's version 2.6 of the app."), true);
});

Deno.test("the meter allows a question's worth of calls and stops a narrator", () => {
  const meter = new SpeechMeter();
  for (let i = 0; i < SPEECH_CALLS_PER_WINDOW; i++) {
    assertEquals(meter.allow("u", 1000), true);
  }
  assertEquals(meter.allow("u", 1000), false);
  assertEquals(meter.allow("someone-else", 1000), true);
  assertEquals(meter.allow("u", 1000 + SPEECH_WINDOW_MS), true);
});
