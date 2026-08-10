import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
  currencyAmount,
  paidSubscriptionTransaction,
} from "./paddle-transaction.ts";

Deno.test("extracts net subscription revenue from a completed transaction", () => {
  assertEquals(
    paidSubscriptionTransaction({
      id: "txn_01",
      subscription_id: "sub_01",
      customer_id: "ctm_01",
      currency_code: "EUR",
      details: {
        totals: {
          total: "24000",
          tax: "4000",
          fee: "1200",
          earnings: "18800",
        },
      },
    }),
    {
      transactionId: "txn_01",
      subscriptionId: "sub_01",
      customerId: "ctm_01",
      currency: "EUR",
      value: 188,
    },
  );
});

Deno.test("uses the currency exponent for minor units", () => {
  assertEquals(currencyAmount("18800", "EUR"), 188);
  assertEquals(currencyAmount("18800", "JPY"), 18800);
});

Deno.test("rejects non-subscription and non-positive transactions", () => {
  assertEquals(
    paidSubscriptionTransaction({
      id: "txn_01",
      currency_code: "EUR",
      details: { totals: { earnings: "18800" } },
    }),
    null,
  );
  assertEquals(
    paidSubscriptionTransaction({
      id: "txn_01",
      subscription_id: "sub_01",
      currency_code: "EUR",
      details: { totals: { earnings: "0" } },
    }),
    null,
  );
});
