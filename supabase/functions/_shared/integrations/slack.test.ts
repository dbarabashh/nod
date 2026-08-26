import { assertEquals, assertThrows } from "jsr:@std/assert";
import {
    isDirect,
    latinise,
    messageFor,
    REPLIES_PER_THREAD,
    searchQuery,
    SLACK_ERRORS,
    THREADS_PER_READ,
    worthReading,
} from "./slack.ts";

// `privacy.md` § 3.16 promises direct and group messages are never read. With
// `search:read` granted that promise no longer rests on the scope list — Slack
// does not divide search by conversation type — so it rests on this function.
Deno.test("a direct message is recognised by Slack's flag", () => {
    assertEquals(isDirect({ id: "C123", is_im: true }), true);
    assertEquals(isDirect({ id: "C123", is_mpim: true }), true);
});

Deno.test("a direct message is recognised by its id when the flags are absent", () => {
    assertEquals(isDirect({ id: "D0123ABCD" }), true);
});

Deno.test("an unidentifiable conversation counts as direct", () => {
    assertEquals(isDirect(undefined), true);
    assertEquals(isDirect({}), true);
});

Deno.test("a channel is left alone", () => {
    assertEquals(isDirect({ id: "C0BQKG9N6EN" }), false);
    assertEquals(
        isDirect({ id: "G0LEGACY", is_im: false, is_mpim: false }),
        false,
    );
});

Deno.test("filters become Slack's modifiers", () => {
    assertEquals(
        searchQuery({ text: "invoice", in: "#pricing", on: "2026-08-26" }, "vlad"),
        "invoice from:@vlad in:#pricing on:2026-08-26",
    );
});

Deno.test("a question about who and when needs no words to look for", () => {
    assertEquals(
        searchQuery({ on: "2026-08-26" }, "vlad"),
        "from:@vlad on:2026-08-26",
    );
});

Deno.test("a window is both ends", () => {
    assertEquals(
        searchQuery({ after: "2026-08-25", before: "2026-08-27" }, null),
        "after:2026-08-25 before:2026-08-27",
    );
});

// A date the model invented in some other shape must fail loudly. Slack treats
// an unparsed modifier as words to search for, so a bad date silently becomes a
// search for the date itself and comes back empty — the exact failure that made
// "no meetings today" believable.
Deno.test("a date Slack would not parse is rejected", () => {
    assertThrows(() => searchQuery({ on: "26/08/2026" }, null));
    assertThrows(() => searchQuery({ after: "yesterday" }, null));
});

Deno.test("a search with no filter at all is rejected rather than run", () => {
    assertThrows(() => searchQuery({}, null));
    assertThrows(() => searchQuery({ text: "   " }, null));
});

// A live connection whose app was never granted a scope is not a broken
// connection. Told to reconnect, somebody runs the same app through the same
// consent screen, gets the same scopes, fails the same way — and concludes the
// integration is broken. That happened.
Deno.test("a missing scope is not an auth failure", () => {
    assertEquals(SLACK_ERRORS.missing_scope, "not_permitted");
    assertEquals(SLACK_ERRORS.not_allowed_token_type, "not_permitted");
});

Deno.test("a dead token still asks for a reconnect", () => {
    assertEquals(SLACK_ERRORS.not_authed, "reauthorize");
    assertEquals(SLACK_ERRORS.invalid_auth, "reauthorize");
    assertEquals(SLACK_ERRORS.account_inactive, "reauthorize");
});

Deno.test("the missing-scope message says reconnecting will not help", () => {
    const said = messageFor("missing_scope");
    assertEquals(said.includes("Reconnecting won't add it"), true);
    assertEquals(said.includes("needs to be reconnected"), false);
});

Deno.test("a dead token's message still sends them to Settings", () => {
    assertEquals(
        messageFor("not_authed").includes("reconnected in Settings"),
        true,
    );
});

// A channel read reported "6 replies" and could not read them: the thread's id
// only exists in the result that would have to ask for it, and the surfaces
// reading this get two calls in total. So the replies ride along.
Deno.test("only the most recent discussions ride along", () => {
    assertEquals(THREADS_PER_READ, 3);
});

Deno.test("a thread rides along bounded, not whole", () => {
    assertEquals(REPLIES_PER_THREAD, 20);
});

Deno.test("a bot post is not what anybody means by what we said", () => {
    assertEquals(worthReading({ text: "deploy finished", bot_id: "B01" }), false);
});

Deno.test("a message with nothing to read is dropped", () => {
    assertEquals(worthReading({ text: "   " }), false);
    assertEquals(worthReading({}), false);
});

Deno.test("a person's message is kept", () => {
    assertEquals(
        worthReading({ text: "we agreed on Friday", user: "U01" }),
        true,
    );
});

// "запроси Влада" against a workspace whose profiles say "Vlad Kampov" matched
// nothing, and the invitation failed on a colleague who was right there. The
// product is used in one language and the workspace is written in another.
Deno.test("a Ukrainian first name reads as the Latin one", () => {
    assertEquals(latinise("Влад"), "vlad");
    assertEquals(latinise("Дмитро"), "dmytro");
    assertEquals(latinise("Олена"), "olena");
});

Deno.test("the letters Ukrainian and Russian disagree on follow Ukrainian", () => {
    assertEquals(latinise("Гриць"), "hryts");
    assertEquals(latinise("Ігор"), "ihor");
});

Deno.test("Russian-only letters are sounded out rather than left to fail", () => {
    assertEquals(latinise("Эдуард"), "eduard");
    assertEquals(latinise("Юля"), "iulia");
});

Deno.test("Latin passes through untouched, so both sides fold to one form", () => {
    assertEquals(latinise("Vlad Kampov"), "vlad kampov");
    assertEquals(latinise("vlad"), latinise("Влад"));
});

Deno.test("an address is left alone", () => {
    assertEquals(latinise("vlad@hellonod.app"), "vlad@hellonod.app");
});
