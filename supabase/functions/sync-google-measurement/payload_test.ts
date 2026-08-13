import { buildMeasurementPayload, isValidGAClientID } from "./payload.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

Deno.test("builds bounded paid conversion payload", () => {
  const payload = buildMeasurementPayload({
    id: "event-id",
    event: "subscription_paid",
    occurred_at: "2026-08-13T06:00:00.000Z",
    ga_client_id: "123456789.987654321",
    value: 24,
    currency: "USD",
  });

  assert(payload !== null, "expected a payload");
  assert(payload?.events[0].name === "subscription_paid", "wrong event name");
  assert(payload?.events[0].params.value === 24, "missing value");
  assert(payload?.events[0].params.currency === "USD", "missing currency");
});

Deno.test("rejects malformed client identifiers", () => {
  assert(!isValidGAClientID(null), "null client id was accepted");
  assert(!isValidGAClientID("raw-cookie"), "unbounded client id was accepted");
  assert(
    buildMeasurementPayload({
      id: "event-id",
      event: "activated",
      occurred_at: "2026-08-13T06:00:00.000Z",
      ga_client_id: "123456789.987654321?email=private",
      value: null,
      currency: null,
    }) === null,
    "malformed client id produced a payload",
  );
});

Deno.test("rejects malformed timestamps", () => {
  assert(
    buildMeasurementPayload({
      id: "event-id",
      event: "trial_started",
      occurred_at: "not-a-timestamp",
      ga_client_id: "123456789.987654321",
      value: null,
      currency: null,
    }) === null,
    "malformed timestamp produced a payload",
  );
});
