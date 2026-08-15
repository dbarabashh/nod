// calendar-sync — reads each connected calendar into `calendar_events`.
//
// Called by pg_cron via `invoke_internal_edge_job`, authenticated with the
// shared `INTERNAL_JOB_SECRET` bearer. Never called by the app: the client has
// no business asking us to read somebody's calendar.
//
// A bounded window rather than a sync token, which is the one decision here that
// shows up everywhere else in the file. Google forbids changing `timeMin` /
// `timeMax` between incremental calls, so a token would mean holding an
// unbounded copy of someone's calendar to save quota we are nowhere near
// spending. The window instead caps what we ever store, and makes deletion fall
// out for free: an event the provider does not return for a window we asked
// about has been moved or cancelled, and the row goes.
//
// Reads `primary` only. A person's other calendars — a partner's, a subscribed
// holiday feed — are not where their meetings are, and asking for the calendar
// list is a wider grant for worse data.
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { proxy } from "../_shared/integrations/nango.ts";
import type { Connection } from "../_shared/integrations/nango.ts";
import type { GoogleEvent } from "../_shared/integrations/googleCalendar.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");

const PROVIDER = "google-calendar";
const CALENDAR_ID = "primary";
const EVENTS_PATH = `calendar/v3/calendars/${CALENDAR_ID}/events`;

// Behind, so a meeting already running is still matchable; ahead, so "what is
// next" has an answer without holding a quarter of somebody's year.
const WINDOW_BEHIND_MS = 2 * 60 * 60 * 1000;
const WINDOW_AHEAD_MS = 7 * 24 * 60 * 60 * 1000;
const PAGE_SIZE = "250";
// A runaway pagination loop would burn the function's whole budget on one
// account and starve everyone after it in the sweep.
const MAX_PAGES = 10;
const CONCURRENCY = 8;
// The caller waits 30 seconds. A run that cannot finish in that budget is worse
// than a short one: pg_net stops listening and every account after the cut-off
// is swept with nothing recorded.
const MAX_ACCOUNTS_PER_RUN = 200;

interface EventRow {
    user_id: string;
    provider: string;
    calendar_id: string;
    external_event_id: string;
    ical_uid: string | null;
    title: string | null;
    conference_url: string | null;
    starts_at: string;
    ends_at: string | null;
    organizer_email: string | null;
    attendees: Array<{ email: string; display?: string; response: string }>;
    updated_at: string;
}

Deno.serve(async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!INTERNAL_JOB_SECRET) {
        console.error("calendar-sync missing env: INTERNAL_JOB_SECRET");
        return json({ error: "Server misconfigured" }, 500);
    }
    if (request.headers.get("Authorization") !== `Bearer ${INTERNAL_JOB_SECRET}`) {
        return json({ error: "Unauthenticated" }, 401);
    }

    const admin = adminClient();
    const { data: connections, error } = await admin
        .from("integration_connections")
        .select("user_id, nango_connection_id")
        .eq("provider", PROVIDER)
        .is("revoked_at", null)
        .limit(MAX_ACCOUNTS_PER_RUN);

    if (error) {
        console.error(`calendar-sync could not list connections: ${error.message}`);
        return json({ error: "Lookup failed" }, 500);
    }
    if (!connections || connections.length === 0) {
        return json({ accounts: 0, events: 0 }, 200);
    }

    const from = new Date(Date.now() - WINDOW_BEHIND_MS);
    const to = new Date(Date.now() + WINDOW_AHEAD_MS);

    let fetched = 0;
    let synced = 0;
    let failed = 0;

    // Concurrent in bounded chunks. Serially, each account is a round trip to
    // Google and back, and `invoke_internal_edge_job` gives the whole sweep 30
    // seconds — enough for a few dozen accounts before the caller stops waiting.
    for (let start = 0; start < connections.length; start += CONCURRENCY) {
        const chunk = connections.slice(start, start + CONCURRENCY);
        const results = await Promise.all(chunk.map(async (row) => {
            const userId = row.user_id as string;
            // One account's revoked grant or rate limit must not end the sweep
            // for everyone else in the chunk.
            try {
                return await syncAccount(
                    admin,
                    userId,
                    { id: row.nango_connection_id as string, provider: PROVIDER },
                    from,
                    to,
                );
            } catch (cause) {
                const message = cause instanceof Error ? cause.message : String(cause);
                console.error(`calendar-sync failed for one account: ${message}`);
                await recordState(admin, userId, message);
                return null;
            }
        }));
        for (const result of results) {
            if (result === null) failed += 1;
            else {
                fetched += result.fetched;
                synced += result.stored;
            }
        }
    }

    // `fetched` and `stored` apart on purpose: without both, an empty calendar
    // and a calendar whose every entry we filtered out look identical.
    console.info(
        `calendar-sync accounts=${connections.length} fetched=${fetched} stored=${synced} failed=${failed}`,
    );
    return json({ accounts: connections.length, fetched, events: synced, failed }, 200);
});

async function syncAccount(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    connection: Connection,
    from: Date,
    to: Date,
): Promise<{ fetched: number; stored: number }> {
    // Stamped before the fetch, and the same value on every row, because the
    // prune below uses it as the cut-off: anything in the window still carrying
    // an older stamp is something the provider stopped returning.
    const stampedAt = new Date().toISOString();
    const events = await fetchWindow(connection, from, to);
    const rows = events
        .map((event) => toRow(userId, event, stampedAt))
        .filter((row): row is EventRow => row !== null);

    if (rows.length > 0) {
        const { error } = await admin
            .from("calendar_events")
            .upsert(rows, { onConflict: "user_id,calendar_id,external_event_id" });
        if (error) throw new Error(`upsert failed: ${error.message}`);
    }

    await pruneWindow(admin, userId, from, to, stampedAt);
    await recordState(admin, userId, null);
    return { fetched: events.length, stored: rows.length };
}

/// Every page of the window. `singleEvents` expands a recurring series into the
/// instances it actually produces — without it a weekly standup is one row with
/// a recurrence rule, and nothing downstream could say which occurrence is now.
async function fetchWindow(connection: Connection, from: Date, to: Date): Promise<GoogleEvent[]> {
    const events: GoogleEvent[] = [];
    let pageToken: string | undefined;

    for (let page = 0; page < MAX_PAGES; page++) {
        const payload = await proxy(connection, EVENTS_PATH, null, {
            method: "GET",
            query: {
                timeMin: from.toISOString(),
                timeMax: to.toISOString(),
                singleEvents: "true",
                orderBy: "startTime",
                showDeleted: "false",
                maxResults: PAGE_SIZE,
                pageToken,
            },
        }) as { items?: GoogleEvent[]; nextPageToken?: string; summary?: string } | null;

        // Which mailbox actually answered. An empty window is ambiguous — no
        // meetings, or the wrong Google account authorized — and the answer is
        // in Google's own reply rather than anywhere we could infer it.
        if (page === 0) {
            console.log(`calendar-sync calendar=${payload?.summary ?? "unknown"} items=${payload?.items?.length ?? 0}`);
        }

        events.push(...(payload?.items ?? []));
        pageToken = payload?.nextPageToken;
        if (!pageToken) return events;
    }

    console.warn(`calendar-sync stopped at ${MAX_PAGES} pages`);
    return events;
}

/// One Google event as we store it, or null for one we have no use for.
///
/// All-day entries are dropped: a birthday or a leave day has no start time to
/// match a recording against, and keeping them would mean storing more of
/// somebody's private calendar than the feature can ever read.
function toRow(userId: string, event: GoogleEvent, stampedAt: string): EventRow | null {
    const startsAt = event.start?.dateTime;
    if (!startsAt || !event.id) return null;

    return {
        user_id: userId,
        provider: PROVIDER,
        calendar_id: CALENDAR_ID,
        external_event_id: event.id,
        // The identity every copy of one meeting shares. `id` differs between
        // the organizer's copy and each attendee's, so it can never answer
        // whether two people are in the same meeting; this can.
        ical_uid: event.iCalUID ?? null,
        title: event.summary ?? null,
        conference_url: conferenceURL(event),
        starts_at: startsAt,
        ends_at: event.end?.dateTime ?? null,
        organizer_email: event.organizer?.email ?? null,
        attendees: attendeesOf(event),
        updated_at: stampedAt,
    };
}

/// Where the meeting actually happens. `hangoutLink` is Google's own shortcut
/// and is present for a Meet link; `conferenceData` is the general form and
/// carries Zoom and Teams when the organizer added one.
function conferenceURL(event: GoogleEvent): string | null {
    if (event.hangoutLink) return event.hangoutLink;
    const video = event.conferenceData?.entryPoints
        ?.find((entry) => entry.entryPointType === "video" && entry.uri);
    return video?.uri ?? null;
}

/// Who is expected, in the two fields that decide anything.
///
/// Rooms are excluded — a booked meeting room is an attendee to Google and noise
/// to us. Everything past the address and the answer is left behind rather than
/// stored: a display name adds nothing the address does not, and this table is
/// already the most personal thing the sync writes.
function attendeesOf(event: GoogleEvent): Array<{ email: string; display?: string; response: string }> {
    return (event.attendees ?? [])
        .filter((attendee) => attendee.email && !attendee.resource)
        .map((attendee) => ({
            email: attendee.email as string,
            // The name on the invitation. Without it the app has only an address
            // to make a name from, and "riwwom@gmail.com" becomes "Riwwom".
            display: attendee.displayName?.trim() || undefined,
            response: attendee.responseStatus ?? "needsAction",
        }));
}

/// Drops what the provider no longer returns for a window it was asked about.
///
/// By the run's own stamp rather than by listing what to keep: every row this
/// pass wrote carries `stampedAt`, so anything older inside the window is an
/// event that has moved or been cancelled. Naming the survivors instead meant
/// serialising up to 2 500 ids into the request — tens of kilobytes of URL, per
/// account, every ten minutes.
///
/// Scoped to the window on purpose: rows outside it are not evidence of
/// anything, and deleting on a wider net would clear a neighbouring window that
/// this call never looked at.
async function pruneWindow(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    from: Date,
    to: Date,
    stampedAt: string,
): Promise<void> {
    const { error } = await admin
        .from("calendar_events")
        .delete()
        .eq("user_id", userId)
        .eq("provider", PROVIDER)
        .eq("calendar_id", CALENDAR_ID)
        .gte("starts_at", from.toISOString())
        .lte("starts_at", to.toISOString())
        .lt("updated_at", stampedAt);
    if (error) console.error(`calendar-sync prune failed: ${error.message}`);
}

async function recordState(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    lastError: string | null,
): Promise<void> {
    const { error } = await admin
        .from("calendar_sync_state")
        .upsert({
            user_id: userId,
            provider: PROVIDER,
            calendar_id: CALENDAR_ID,
            synced_at: new Date().toISOString(),
            last_error: lastError,
        }, { onConflict: "user_id,provider,calendar_id" });
    if (error) console.error(`calendar-sync state write failed: ${error.message}`);
}
