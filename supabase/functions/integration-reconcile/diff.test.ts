import { assertEquals } from "jsr:@std/assert@1.0.14";
import { diff } from "./diff.ts";

const dev = { provider: "linear", accountId: "apn_old" };
const prod = { provider: "linear", accountId: "apn_new" };

Deno.test("a provider nobody held is arriving", () => {
    const { arrived, departed } = diff([], [dev]);
    assertEquals(arrived, [dev]);
    assertEquals(departed, []);
});

Deno.test("the same account on both sides is not a change", () => {
    const { arrived, departed } = diff([dev], [dev]);
    assertEquals(arrived, []);
    assertEquals(departed, []);
});

// The case this function exists for. A grant that died at the provider and was
// authorized again mints a fresh account under a provider we already hold; keyed
// on the name alone that reads as "nothing moved", the row keeps the dead
// account, and reconnecting can never repair it.
Deno.test("a fresh account under a held provider is arriving", () => {
    const { arrived, departed } = diff([dev], [prod]);
    assertEquals(arrived, [prod]);
    assertEquals(departed, []);
});

Deno.test("a provider the broker no longer reports has departed", () => {
    const { arrived, departed } = diff([dev], []);
    assertEquals(arrived, []);
    assertEquals(departed, ["linear"]);
});

// Re-granting one product must not read as losing it: `departed` fires
// `purge_provider_data`, so a provider named in both lists would delete the data
// belonging to the connection that just replaced it.
Deno.test("a re-granted provider is not also departing", () => {
    const { arrived, departed } = diff([dev], [prod]);
    assertEquals(departed.includes("linear"), false);
    assertEquals(arrived.length, 1);
});

Deno.test("providers move independently of each other", () => {
    const { arrived, departed, nowLive } = diff(
        [dev, { provider: "slack", accountId: "apn_slack" }],
        [prod, { provider: "github", accountId: "apn_gh" }],
    );
    assertEquals(arrived, [prod, { provider: "github", accountId: "apn_gh" }]);
    assertEquals(departed, ["slack"]);
    assertEquals(nowLive.sort(), ["github", "linear"]);
});
