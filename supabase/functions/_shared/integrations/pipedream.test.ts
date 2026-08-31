import { assertEquals } from "jsr:@std/assert";
import { customOAuthAppID, providerDetail } from "./pipedream.ts";

function withEnv(vars: Record<string, string>, body: () => void) {
    for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
    try {
        body();
    } finally {
        for (const k of Object.keys(vars)) Deno.env.delete(k);
    }
}

// Connect runs Pipedream's own OAuth client unless the link names ours, so a
// custom client that is created but never named is one nobody authorizes — and
// the symptom is a healthy connection whose calls fail with `missing_scope`.
Deno.test("no client set leaves Pipedream's own in place", () => {
    assertEquals(customOAuthAppID("slack"), null);
});

Deno.test("a provider's own client is found by its name", () => {
    withEnv({ PIPEDREAM_OAUTH_APP_SLACK: "oa_abc123" }, () => {
        assertEquals(customOAuthAppID("slack"), "oa_abc123");
    });
});

/// Our provider names carry hyphens; environment variables cannot.
Deno.test("a hyphenated provider maps to an underscored variable", () => {
    withEnv({ PIPEDREAM_OAUTH_APP_GOOGLE_CALENDAR: "oa_cal" }, () => {
        assertEquals(customOAuthAppID("google-calendar"), "oa_cal");
    });
});

Deno.test("one provider's client is not another's", () => {
    withEnv({ PIPEDREAM_OAUTH_APP_SLACK: "oa_abc123" }, () => {
        assertEquals(customOAuthAppID("linear"), null);
    });
});

/// A variable set to whitespace is a variable somebody meant to unset. Passed
/// on, it names a client that does not exist and the authorization fails.
Deno.test("an empty value is no client rather than an empty one", () => {
    withEnv({ PIPEDREAM_OAUTH_APP_SLACK: "   " }, () => {
        assertEquals(customOAuthAppID("slack"), null);
    });
});

// A failed call that only says "the provider rejected it" leaves the model with
// nothing to answer "why?" with, and the person asking gets a shrug.
Deno.test("Google's nested error is the detail", () => {
    assertEquals(
        providerDetail({
            error: {
                code: 403,
                message: "The caller does not have permission",
                status: "PERMISSION_DENIED",
            },
        }),
        "The caller does not have permission",
    );
});

Deno.test("Jira's list of messages gives up its first", () => {
    assertEquals(
        providerDetail({ errorMessages: ["Issue does not exist"], errors: {} }),
        "Issue does not exist",
    );
});

Deno.test("an array of errors gives up its first message", () => {
    assertEquals(
        providerDetail({ errors: [{ message: "Not a recognized id." }] }),
        "Not a recognized id.",
    );
});

Deno.test("a flat message is the detail", () => {
    assertEquals(providerDetail({ message: "Bad credentials" }), "Bad credentials");
});

Deno.test("an error that is itself a string is the detail", () => {
    assertEquals(providerDetail({ error: "invalid_grant" }), "invalid_grant");
});

/// A provider that answers a failure with HTML or nothing at all must not turn
/// into an empty `rejected the request: .`
Deno.test("no readable detail is no detail", () => {
    assertEquals(providerDetail(null), null);
    assertEquals(providerDetail({ ok: false }), null);
    assertEquals(providerDetail({ message: "   " }), null);
});

Deno.test("a long detail is cut to stay a tool result", () => {
    const detail = providerDetail({ message: "x".repeat(500) });
    assertEquals(detail?.length, 300);
    assertEquals(detail?.endsWith("…"), true);
});

/// Newlines in a stack trace would break the one-line-per-event log rule and
/// read as three failures in the transcript.
Deno.test("a multi-line detail collapses to one line", () => {
    assertEquals(providerDetail({ message: "first\n  second" }), "first second");
});
