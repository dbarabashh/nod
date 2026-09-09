import { assert, assertEquals, assertFalse, assertThrows } from "jsr:@std/assert@1.0.14";
import { ActionError } from "./errors.ts";
import { appended, closedOf, hasID, isSearchPaywalled, keyOf, notesOf, summarise } from "./asana.ts";

// Only the paid-feature refusal falls back to the person's own tasks; a revoked
// grant or a throttled call must still fail as itself.
Deno.test("a 402 from asana's search is the paywall", () => {
    assert(isSearchPaywalled(new ActionError("provider_error", "asana rejected the request", 502, undefined, 402)));
});

Deno.test("any other refusal is not the paywall", () => {
    assertFalse(isSearchPaywalled(new ActionError("reauthorize", "asana rejected the request", 502, undefined, 401)));
    assertFalse(isSearchPaywalled(new ActionError("provider_error", "asana rejected the request", 502, undefined, 429)));
    assertFalse(isSearchPaywalled(new ActionError("provider_error", "no data", 502)));
    assertFalse(isSearchPaywalled(new Error("network")));
});

// The chat tool was written in Asana's words and the desktop files in the
// contract's; both have to keep working.
Deno.test("a task is addressed by key or by id", () => {
    assertEquals(keyOf({ key: "123" }), "123");
    assertEquals(keyOf({ id: "123" }), "123");
    assertEquals(keyOf({ key: "1", id: "2" }), "1");
    const error = assertThrows(() => keyOf({}), ActionError);
    assertEquals(error.message, "`key` is required.");
});

Deno.test("closed and completed are the same flag, absent when neither is sent", () => {
    assertEquals(closedOf({ closed: "true" }), true);
    assertEquals(closedOf({ completed: false }), false);
    assertEquals(closedOf({}), undefined);
    assertThrows(() => closedOf({ closed: "yes" }), ActionError);
});

Deno.test("description and notes are the same text", () => {
    assertEquals(notesOf({ description: " spec " }), "spec");
    assertEquals(notesOf({ notes: "spec" }), "spec");
    assertEquals(notesOf({}), "");
    assertEquals(notesOf({ notes: 3 }), "");
});

Deno.test("a note is added under a rule, never written over", () => {
    assertEquals(appended("Original spec", "Decided in standup"), "Original spec\n\n---\n\nDecided in standup");
    assertEquals(appended("", "Decided in standup"), "Decided in standup");
    assertEquals(appended(undefined, "Decided in standup"), "Decided in standup");
});

Deno.test("a summary answers the contract in both vocabularies", () => {
    assert(hasID({ gid: "9" }));
    assertFalse(hasID({ gid: "" }));
    assertFalse(hasID(null));
    assertEquals(
        summarise({ gid: "9", name: "Ship", completed: true, permalink_url: "https://app.asana.com/0/1/9", due_on: null }),
        {
            key: "9",
            id: "9",
            title: "Ship",
            url: "https://app.asana.com/0/1/9",
            closed: true,
            completed: true,
            due: null,
            assignee: null,
            project: null,
        },
    );
});
