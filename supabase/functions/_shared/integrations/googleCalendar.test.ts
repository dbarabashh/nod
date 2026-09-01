import { assert, assertFalse } from "jsr:@std/assert";
import { startMatches, titleMatches } from "./googleCalendar.ts";

// The approval card shows a title while the wire carries an id, and this check
// is the only thing pairing them. Case and whitespace are the model's noise,
// not a different event; different words are.
Deno.test("a retyped title still names the same event", () => {
    assert(titleMatches("Team Standup", "Team Standup"));
    assert(titleMatches("team standup", "Team Standup"));
    assert(titleMatches("  Team Standup ", "Team Standup"));
});

Deno.test("a different or missing title is refused", () => {
    assertFalse(titleMatches("Team Standup", "1:1 with Alina"));
    assertFalse(titleMatches("Team Standup", null));
    assertFalse(titleMatches("Team Standup", undefined));
    assertFalse(titleMatches("Team Standup", ""));
});

// An untitled event is listed as "(no title)"; refusing those words would make
// it permanently unactionable, with a "list again" hint that loops forever.
Deno.test("the (no title) sentinel names an untitled event", () => {
    assert(titleMatches("(no title)", null));
    assert(titleMatches("(no title)", "  "));
    assertFalse(titleMatches("(no title)", "Team Standup"));
});

// The title cannot tell Thursday's standup from Tuesday's — every occurrence
// of a recurring meeting shares it — so the start is verified too.
Deno.test("the approved start must be the event's start", () => {
    const at = (dateTime: string) => ({ start: { dateTime } });
    assert(startMatches("2026-09-03T10:00:00+02:00", at("2026-09-03T08:00:00Z")));
    assertFalse(startMatches("2026-09-10T10:00:00+02:00", at("2026-09-03T08:00:00Z")));
    assertFalse(startMatches("not a time", at("2026-09-03T08:00:00Z")));
    assert(startMatches("2026-09-03", { start: { date: "2026-09-03" } }));
    assertFalse(startMatches("2026-09-04", { start: { date: "2026-09-03" } }));
    assertFalse(startMatches("2026-09-03T08:00:00Z", {}));
});
