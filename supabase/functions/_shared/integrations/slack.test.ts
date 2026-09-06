import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
    byAuthor,
    fromAChannel,
    isDirect,
    latinise,
    messageFor,
    REPLIES_PER_THREAD,
    type SearchHit,
    searchPages,
    searchPlan,
    SLACK_ERRORS,
    THREADS_PER_READ,
    worthQuoting,
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

// `assistant.search.context` has none of the `search.messages` modifiers.
// `from:@vlad in:#pricing on:2026-08-26` in its `modifiers` argument is
// refused as `invalid_arguments` — which is what every search with a person or
// a day in it did, until nobody had ever seen a Slack search succeed.
const vlad = { id: "U0VLAD", name: "vlad" };
const pricing = { id: "C0PRICING", name: "pricing" };

Deno.test("a person, a channel and a day become the method's own arguments", () => {
    const plan = searchPlan(
        { text: "invoice", in: "#pricing", on: "2026-08-26" },
        vlad,
        pricing,
    );
    assertEquals(plan.query, "invoice");
    assertEquals(plan.authorID, "U0VLAD");
    assertEquals(plan.channelID, "C0PRICING");
    assertEquals(plan.after, Date.UTC(2026, 7, 26) / 1000 - 1);
    assertEquals(plan.before, Date.UTC(2026, 7, 27) / 1000);
    assertEquals(plan.described, "invoice from:@vlad in:#pricing on:2026-08-26");
});

// The method requires a query. A question about who or when has no words in
// it, so the person stands in — a semantic search for their name over their
// own messages is the nearest thing to "everything they said".
Deno.test("a question about who and when still has something to search for", () => {
    const plan = searchPlan({ on: "2026-08-26" }, vlad, null);
    assertEquals(plan.query, "vlad");
    assertEquals(plan.described, "from:@vlad on:2026-08-26");
    assertEquals(
        searchPlan({ after: "2026-08-25" }, null, null).query,
        "what was said",
    );
});

Deno.test("a window is both ends, and a day after is the day after", () => {
    const plan = searchPlan(
        { after: "2026-08-25", before: "2026-08-27" },
        null,
        null,
    );
    assertEquals(plan.after, Date.UTC(2026, 7, 26) / 1000 - 1);
    assertEquals(plan.before, Date.UTC(2026, 7, 27) / 1000);
    assertEquals(plan.described, "after:2026-08-25 before:2026-08-27");
});

Deno.test("a single day wins over a window it was given beside", () => {
    const plan = searchPlan(
        { on: "2026-08-26", after: "2026-01-01" },
        null,
        null,
    );
    assertEquals(plan.after, Date.UTC(2026, 7, 26) / 1000 - 1);
    assertEquals(plan.described, "on:2026-08-26");
});

// A date the model invented in some other shape must fail loudly rather than
// be sent on for Slack to refuse the whole call.
Deno.test("a date Slack would not parse is rejected", () => {
    assertThrows(() => searchPlan({ on: "26/08/2026" }, null, null));
    assertThrows(() => searchPlan({ after: "yesterday" }, null, null));
});

// Shaped like a date and not one: `Date.parse` answers NaN, which JSON sends
// on as null, and Slack either refuses the call or quietly drops the day.
Deno.test("a day that is not on the calendar is rejected", () => {
    assertThrows(() => searchPlan({ on: "2026-08-32" }, null, null));
    assertThrows(() => searchPlan({ before: "2026-13-01" }, null, null));
    assertThrows(() => searchPlan({ on: "2026-02-30" }, null, null));
});

Deno.test("a search without dates sends no window", () => {
    const plan = searchPlan({ text: "invoice" }, null, null);
    assertEquals(plan.after, undefined);
    assertEquals(plan.before, undefined);
});

const inChannel = (author: string, n: number): SearchHit => ({
    author_user_id: author,
    author_name: author,
    channel_id: "C0PRICING",
    channel_name: "pricing",
    content: `message ${n}`,
    message_ts: `${1_700_000_000 + n}.000`,
});

function pagesOf(pages: SearchHit[][]) {
    const calls: (string | undefined)[] = [];
    const fetch = (cursor: string | undefined) => {
        calls.push(cursor);
        const index = cursor ? Number(cursor) : 0;
        const next = index + 1 < pages.length ? String(index + 1) : "";
        return Promise.resolve({
            results: { messages: pages[index] ?? [] },
            response_metadata: { next_cursor: next },
        });
    };
    return { fetch, calls };
}

// The method has no author argument. A person's page-two message must not
// become "they said nothing" because twenty other people posted after them.
Deno.test("a person's message on the second page is found", async () => {
    const { fetch, calls } = pagesOf([
        Array.from({ length: 20 }, (_, n) => inChannel("U0OTHER", n)),
        [inChannel("U0VLAD", 20), inChannel("U0OTHER", 21)],
    ]);
    const plan = searchPlan({ from: "Vlad" }, { id: "U0VLAD", name: "vlad" }, null);
    const found = await searchPages(plan, fetch);
    assertEquals(found.hits.map((hit) => hit.content), ["message 20"]);
    assertEquals(found.seen, 22);
    assertEquals(found.truncated, false);
    assertEquals(calls, [undefined, "1"]);
});

Deno.test("a search about nobody in particular turns one page", async () => {
    const { fetch, calls } = pagesOf([[inChannel("U0OTHER", 0)], [inChannel("U0OTHER", 1)]]);
    const found = await searchPages(searchPlan({ text: "invoice" }, null, null), fetch);
    assertEquals(found.hits.length, 1);
    assertEquals(found.truncated, true);
    assertEquals(calls, [undefined]);
});

Deno.test("turning pages stops at the cap and says so", async () => {
    const { fetch, calls } = pagesOf(Array.from({ length: 8 }, (_, p) => [inChannel("U0OTHER", p)]));
    const plan = searchPlan({ from: "Vlad" }, { id: "U0VLAD", name: "vlad" }, null);
    const found = await searchPages(plan, fetch);
    assertEquals(found.hits, []);
    assertEquals(found.seen, 5);
    assertEquals(found.truncated, true);
    assertEquals(calls.length, 5);
});

Deno.test("a search with no filter at all is rejected rather than run", () => {
    assertThrows(() => searchPlan({}, null, null));
    assertThrows(() => searchPlan({ text: "   " }, null, null));
});

// The filters are validated before the roster is fetched, so the unresolved
// pass has to accept a `from` it has not looked up yet.
Deno.test("an unresolved person still counts as a filter", () => {
    assertEquals(searchPlan({ from: "Vlad" }, null, null).described, "");
    assertEquals(searchPlan({ from: "Vlad" }, null, null).authorID, undefined);
});

// The method has no author argument, so the person is a filter on the page
// that comes back. A hit that names nobody cannot be shown to be theirs.
Deno.test("only the person's own messages survive an author filter", () => {
    assertEquals(byAuthor({ author_user_id: "U0VLAD" }, "U0VLAD"), true);
    assertEquals(byAuthor({ author_user_id: "U0OTHER" }, "U0VLAD"), false);
    assertEquals(byAuthor({}, "U0VLAD"), false);
    assertEquals(byAuthor({}, undefined), true);
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

// ── What a search result has to clear before the model sees it ──────────────

Deno.test("a search hit from a channel is kept", () => {
    assertEquals(
        fromAChannel({ channel_id: "C0BQKG9N6EN", channel_name: "pricing" }),
        true,
    );
});

// The second line on the promise in `privacy.md` § 3.16. `channel_types` asks
// Slack for channels only; if that argument were ever dropped or defaulted
// away, this is what still keeps a direct message out of an answer.
Deno.test("a search hit from a direct message is dropped", () => {
    assertEquals(
        fromAChannel({ channel_id: "D0123ABCD", channel_name: "dmytro" }),
        false,
    );
});

// Search names every channel it returns, so a nameless conversation is not one.
Deno.test("a search hit with no channel name is treated as direct", () => {
    assertEquals(fromAChannel({ channel_id: "C0BQKG9N6EN" }), false);
    assertEquals(
        fromAChannel({ channel_id: "C0BQKG9N6EN", channel_name: "  " }),
        false,
    );
    assertEquals(fromAChannel({}), false);
});

Deno.test("a bot's search hit is dropped, as it is in a channel read", () => {
    assertEquals(
        worthQuoting({ content: "deploy finished", is_author_bot: true }),
        false,
    );
});

Deno.test("a search hit with nothing said is dropped", () => {
    assertEquals(worthQuoting({ content: "   " }), false);
    assertEquals(worthQuoting({}), false);
});

Deno.test("a person's search hit is kept", () => {
    assertEquals(
        worthQuoting({ content: "shipping tomorrow", is_author_bot: false }),
        true,
    );
});
