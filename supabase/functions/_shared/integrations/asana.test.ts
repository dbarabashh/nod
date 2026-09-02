import { assert, assertFalse } from "jsr:@std/assert@1.0.14";
import { ActionError } from "./errors.ts";
import { isSearchPaywalled } from "./asana.ts";

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
