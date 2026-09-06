// How often a connected calendar may be read.
//
// Every read is one metered request through the Connect proxy, so the floors
// below are the cost model: the app asks for a read and says why, the server
// refuses anything sooner than the floor for that reason, and nothing reads a
// calendar on its own more than once a day. Held apart from the function so
// the arithmetic is testable and so the client's mirror of it
// (`CalendarSyncReason.floor`) has one place to be checked against.

/// Why the app is asking, and the least time that must have passed since the
/// calendar was last read for that ask to be honoured.
export const FLOOR_SECONDS = {
    /// Half an hour, not fifteen minutes: each read is a metered broker call and
    /// the app is opened far more often than a calendar changes.
    open: 30 * 60,
    idle: 60 * 60,
    /// A meeting on the calendar starts within half an hour — the one moved
    /// five minutes before it begins is the case the read exists for.
    approaching: 5 * 60,
    /// A recording is starting and the invitation is about to be matched.
    call: 2 * 60,
} as const;

export type Reason = keyof typeof FLOOR_SECONDS;

export function isReason(value: unknown): value is Reason {
    return typeof value === "string" && Object.hasOwn(FLOOR_SECONDS, value);
}

/// The unattended safety net: once a day, for an account the app has not
/// asked about since yesterday. Under a day so the daily run is not skipped
/// by a read that happened a minute after yesterday's.
export const SWEEP_STALE_SECONDS = 20 * 60 * 60;

/// The most proxied requests one calendar gets in a calendar month, whatever
/// the app asks — pages count, since pages are what the proxy meters. Above a
/// heavy month (six meetings a day, back to back) and well under the old
/// unconditional sweep; a calendar that hits it is a client misbehaving, and
/// the tally that backs it is best-effort. A `call` read is not held to it:
/// one per recording, and the read that names the meeting.
export const MONTHLY_READ_CAP = 3000;

export function monthlyCap(reason: Reason): number | null {
    return reason === "call" ? null : MONTHLY_READ_CAP;
}

/// When a read for `reason` is next allowed, given when the calendar was last
/// read. Never earlier than `lastReadAt` plus the floor; now for a calendar
/// never read.
export function nextAllowedAt(reason: Reason, lastReadAt: string | null, now: Date): Date {
    if (!lastReadAt) return now;
    const last = new Date(lastReadAt).getTime();
    if (Number.isNaN(last)) return now;
    return new Date(Math.max(now.getTime(), last + FLOOR_SECONDS[reason] * 1000));
}

export function mayRead(reason: Reason, lastReadAt: string | null, now: Date): boolean {
    return nextAllowedAt(reason, lastReadAt, now).getTime() <= now.getTime();
}

export function isSweepDue(lastReadAt: string | null, now: Date): boolean {
    if (!lastReadAt) return true;
    const last = new Date(lastReadAt).getTime();
    if (Number.isNaN(last)) return true;
    return now.getTime() - last >= SWEEP_STALE_SECONDS * 1000;
}
