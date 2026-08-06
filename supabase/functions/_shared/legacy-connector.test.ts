import { assertEquals } from "jsr:@std/assert@1";
import {
  legacyConnectorExpired,
  legacyConnectorHeaders,
} from "./legacy-connector.ts";

Deno.test("legacy connector remains available before sunset", () => {
  assertEquals(
    legacyConnectorExpired(
      Date.parse("2026-08-06T00:00:00Z"),
      "2026-11-04T00:00:00Z",
    ),
    false,
  );
});

Deno.test("legacy connector expires at sunset", () => {
  assertEquals(
    legacyConnectorExpired(
      Date.parse("2026-11-04T00:00:00Z"),
      "2026-11-04T00:00:00Z",
    ),
    true,
  );
});

Deno.test("invalid or missing sunset keeps rollback available", () => {
  assertEquals(legacyConnectorExpired(Date.now(), ""), false);
  assertEquals(legacyConnectorExpired(Date.now(), "not-a-date"), false);
});

Deno.test("legacy responses disclose deprecation and sunset", () => {
  const headers = legacyConnectorHeaders("2026-11-04T00:00:00Z");
  assertEquals(headers.Deprecation, "true");
  assertEquals(headers.Sunset, "Wed, 04 Nov 2026 00:00:00 GMT");
  assertEquals(
    headers.Link,
    '<https://hellonod.app/connectors>; rel="deprecation"',
  );
});
