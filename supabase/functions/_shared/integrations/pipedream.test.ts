import { assertEquals } from "jsr:@std/assert";
import { customOAuthAppID } from "./pipedream.ts";

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
