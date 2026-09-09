import { assertEquals } from "jsr:@std/assert";
import { filedReference } from "./filed.ts";

Deno.test("a row with every external column is a reference", () => {
    assertEquals(
        filedReference({ external_provider: "linear", external_key: "NOD-9", external_url: "https://linear.app/x/NOD-9" }),
        { provider: "linear", key: "NOD-9", url: "https://linear.app/x/NOD-9" },
    );
});

Deno.test("a row missing any external column is not filed", () => {
    assertEquals(filedReference({ external_provider: "linear", external_key: "NOD-9", external_url: null }), null);
    assertEquals(filedReference({ external_provider: null, external_key: null, external_url: null }), null);
    assertEquals(filedReference(null), null);
});
