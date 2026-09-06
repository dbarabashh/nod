import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.14";
import {
    FLOOR_SECONDS,
    isReason,
    isSweepDue,
    mayRead,
    MONTHLY_READ_CAP,
    monthlyCap,
    nextAllowedAt,
    SWEEP_STALE_SECONDS,
} from "./calendarRefresh.ts";

const now = new Date("2026-09-02T10:00:00.000Z");
const ago = (seconds: number) => new Date(now.getTime() - seconds * 1000).toISOString();

Deno.test("a calendar never read may be read for any reason", () => {
    for (const reason of ["open", "idle", "approaching", "call"] as const) {
        assert(mayRead(reason, null, now));
        assertEquals(nextAllowedAt(reason, null, now), now);
    }
});

// The whole point: a request sooner than the floor is refused whatever the
// client says, and the floors are ordered by how much freshness the reason
// is worth paying for.
Deno.test("each reason waits its own floor", () => {
    assertFalse(mayRead("open", ago(29 * 60), now));
    assert(mayRead("open", ago(30 * 60), now));
    assertFalse(mayRead("idle", ago(59 * 60), now));
    assert(mayRead("idle", ago(60 * 60), now));
    assertFalse(mayRead("approaching", ago(4 * 60), now));
    assert(mayRead("approaching", ago(5 * 60), now));
    assertFalse(mayRead("call", ago(119), now));
    assert(mayRead("call", ago(120), now));
});

Deno.test("floors are ordered by urgency", () => {
    assert(FLOOR_SECONDS.call < FLOOR_SECONDS.approaching);
    assert(FLOOR_SECONDS.approaching < FLOOR_SECONDS.open);
    assert(FLOOR_SECONDS.open < FLOOR_SECONDS.idle);
});

Deno.test("next allowed is the last read plus the floor", () => {
    const next = nextAllowedAt("approaching", ago(60), now);
    assertEquals(next.getTime() - now.getTime(), (FLOOR_SECONDS.approaching - 60) * 1000);
});

// A clock that ran backwards, or a stamp from a future run, must not lock the
// calendar for longer than the floor from now.
Deno.test("a last read in the future still allows a read after one floor", () => {
    const future = new Date(now.getTime() + 3600 * 1000).toISOString();
    const next = nextAllowedAt("call", future, now);
    assert(next.getTime() > now.getTime());
});

Deno.test("an unreadable stamp does not block the read", () => {
    assert(mayRead("open", "not a date", now));
    assert(isSweepDue("not a date", now));
});

Deno.test("only the four reasons are accepted", () => {
    assert(isReason("open"));
    assert(isReason("call"));
    assertFalse(isReason("sweep"));
    assertFalse(isReason(""));
    assertFalse(isReason(undefined));
    assertFalse(isReason("constructor"));
});

// The safety net is for an account nobody asked about, not a second sweep of
// everyone; the stale window is under a day so the daily run cannot be
// skipped by a read minutes after the previous one.
Deno.test("the sweep reads only what the app has not asked about", () => {
    assert(isSweepDue(null, now));
    assert(isSweepDue(ago(SWEEP_STALE_SECONDS), now));
    assertFalse(isSweepDue(ago(SWEEP_STALE_SECONDS - 1), now));
    assert(SWEEP_STALE_SECONDS < 24 * 60 * 60);
});

// A normal month through the floors is about 800 reads and a heavy one — six
// meetings a day, back to back — about 1,200 (the model in
// `supabase/integrations/README.md`); the cap sits above both and below the
// retired ten-minute sweep, so it catches a misbehaving client without
// touching anyone else.
Deno.test("the monthly cap fits between a heavy month and the retired sweep", () => {
    const retiredSweep = 6 * 24 * 30;
    const heavyMonth = 1200;
    assert(MONTHLY_READ_CAP > heavyMonth * 2);
    assert(MONTHLY_READ_CAP < retiredSweep);
});

// The read that names the meeting is the one worth keeping when the budget is
// gone; it is bounded by recordings, not by a timer.
Deno.test("a starting recording is not held to the cap", () => {
    assertEquals(monthlyCap("call"), null);
    assertEquals(monthlyCap("open"), MONTHLY_READ_CAP);
    assertEquals(monthlyCap("approaching"), MONTHLY_READ_CAP);
});
