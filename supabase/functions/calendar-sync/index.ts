// calendar-sync — reads a connected calendar into `calendar_events`.
//
// Two callers:
//   • The app, with the user's JWT and a reason (`open`, `idle`, `approaching`,
//     `call`). It reads the caller's own calendar and nobody else's, and only
//     when that reason's floor has passed since the last read — a request
//     sooner is answered "not yet" without touching the provider.
//   • pg_cron via `invoke_internal_edge_job`, with the `INTERNAL_JOB_SECRET`
//     bearer, once a day. It reads the accounts the app has not asked about
//     since yesterday and nothing else.
//
// Every read is a metered Connect proxy request, and the previous shape of
// this function — an unconditional sweep of every account every ten minutes —
// spent 4,320 of them per calendar a month whether or not anyone was at their
// Mac. The floors in `calendarRefresh.ts` are what replaced that. See
// `supabase/integrations/README.md` for the cost model.
//
// A bounded window rather than a sync token, which is the one decision here that
// shows up everywhere else in the file. Google forbids changing `timeMin` /
// `timeMax` between incremental calls, so a token would mean holding an
// unbounded copy of someone's calendar. The window instead caps what we ever
// store, and makes deletion fall out for free: an event the provider does not
// return for a window we asked about has been moved or cancelled, and the row
// goes.
//
// Reads `primary` only. A person's other calendars — a partner's, a subscribed
// holiday feed — are not where their meetings are, and asking for the calendar
// list is a wider grant for worse data.
import { isObject, json } from "../_shared/http.ts";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { ActionError, proxy } from "../_shared/integrations/pipedream.ts";
import type { Connection } from "../_shared/integrations/pipedream.ts";
import { assertProviderPermitted, barredUsers } from "../_shared/integrations/policy.ts";
import { apiBase } from "../_shared/integrations/registry.ts";
import { briefingsV1Enabled, ingestionV2Enabled } from "../_shared/context-platform/flags.ts";
import { completeOnce } from "../_shared/complete.ts";
import {
    FLOOR_SECONDS,
    isReason,
    MONTHLY_READ_CAP,
    monthlyCap,
    nextAllowedAt,
    type Reason,
    SWEEP_STALE_SECONDS,
} from "../_shared/integrations/calendarRefresh.ts";
import {
    CALENDAR_ID,
    type EventRow,
    EVENTS_PATH,
    type GoogleEvent,
    PROVIDER,
    toRow,
} from "../_shared/integrations/googleCalendar.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");

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

type Admin = ReturnType<typeof adminClient>;

Deno.serve(async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

    const bearer = request.headers.get("Authorization");
    if (INTERNAL_JOB_SECRET && bearer === `Bearer ${INTERNAL_JOB_SECRET}`) {
        return sweep(adminClient());
    }

    const auth = await authenticate(request);
    if (auth instanceof Response) {
        // The cron's bearer lands here when the secret is unset, and a 401 in
        // the job history reads as a bad token rather than a missing one.
        if (!INTERNAL_JOB_SECRET) console.error("calendar-sync missing env: INTERNAL_JOB_SECRET");
        return auth;
    }

    const reason = await reasonOf(request);
    if (!reason) return json({ error: "Unknown reason" }, 400);
    return readForCaller(adminClient(), auth.user.id, reason);
});

async function reasonOf(request: Request): Promise<Reason | null> {
    const body = await request.json().catch(() => null);
    if (!isObject(body)) return null;
    return isReason(body.reason) ? body.reason : null;
}

/// The app's ask: the caller's own calendar, if its floor has passed.
///
/// Response: `{ connected, read, synced_at, capped }` — `synced_at` is when
/// the calendar was last read after this call, fresh or not, so the client can
/// keep its own copy of the floor without a second round trip; `capped` names
/// the month's budget as the reason for a refusal, because the floor would
/// otherwise say "ask again in five minutes" for the rest of the month.
async function readForCaller(admin: Admin, userId: string, reason: Reason): Promise<Response> {
    const { data: row, error } = await admin
        .from("integration_connections")
        .select("broker_account_id")
        .eq("user_id", userId)
        .eq("provider", PROVIDER)
        .is("revoked_at", null)
        .maybeSingle();
    if (error) {
        console.error(`calendar-sync could not read the caller's connection: ${error.message}`);
        return json({ error: "Lookup failed" }, 500);
    }
    if (!row) return json({ connected: false, read: false, synced_at: null }, 200);

    // The organization's answer holds here as it does on every other path: a
    // company that switched the calendar off is not overruled by its member
    // asking nicely. A check that could not run is a 503, not a refusal —
    // somebody is in front of this request, and "your organization does not
    // permit" is not something to say on the strength of a database hiccup.
    try {
        await assertProviderPermitted(userId, PROVIDER);
    } catch (cause) {
        if (cause instanceof ActionError) return json({ error: cause.message }, cause.status);
        throw cause;
    }

    const claim = await claimRead(admin, userId, FLOOR_SECONDS[reason], monthlyCap(reason));
    if (claim === null) return json({ error: "Lookup failed" }, 500);
    if (claim !== "read") {
        const syncedAt = await lastReadAt(admin, userId);
        const next = claim === "capped" ? startOfNextMonth(new Date()) : nextAllowedAt(reason, syncedAt, new Date());
        console.info(`calendar-sync refused reason=${reason} because=${claim} next=${next.toISOString()}`);
        return json({ connected: true, read: false, synced_at: syncedAt, capped: claim === "capped" }, 200);
    }

    const now = Date.now();
    try {
        const result = await syncAccount(
            admin,
            userId,
            connectionFor(userId, row.broker_account_id as string),
            new Date(now - WINDOW_BEHIND_MS),
            new Date(now + WINDOW_AHEAD_MS),
            `calendar-${reason}`,
        );
        console.info(`calendar-sync reason=${reason} fetched=${result.fetched} stored=${result.stored}`);
        return json({ connected: true, read: true, synced_at: result.syncedAt }, 200);
    } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause);
        console.error(`calendar-sync failed for the caller: ${message}`);
        await recordState(admin, userId, message);
        return json({ error: "Calendar read failed" }, 502);
    }
}

/// The daily safety net: accounts the app has not asked about since yesterday.
async function sweep(admin: Admin): Promise<Response> {
    // Selected and ordered in the database, longest-unread first, before the
    // page is cut: a page taken from every connection would fill with active
    // accounts that are never due, and whoever sat past it would never be swept.
    const { data: due, error } = await admin.rpc("calendar_sweep_candidates", {
        p_provider: PROVIDER,
        p_calendar: CALENDAR_ID,
        p_stale_before: new Date(Date.now() - SWEEP_STALE_SECONDS * 1000).toISOString(),
        p_limit: MAX_ACCOUNTS_PER_RUN,
    }) as { data: Array<{ user_id: string; broker_account_id: string }> | null; error: { message: string } | null };

    if (error) {
        console.error(`calendar-sync could not list connections: ${error.message}`);
        return json({ error: "Lookup failed" }, 500);
    }
    if (!due || due.length === 0) {
        return json({ accounts: 0, events: 0 }, 200);
    }

    // An organization that switched the calendar off switched off this sweep
    // for its people, and this is the only place that could honour it: nobody
    // asked for this run, so there is no request to refuse and no client to
    // hide a button.
    const barred = await barredUsers(due.map((row) => row.user_id as string), PROVIDER);
    const permitted = due.filter((row) => !barred.has(row.user_id as string));
    if (barred.size > 0) {
        console.info(`calendar-sync skipped ${barred.size} account(s) their organization does not permit`);
        // Stamped so they take their turn at the back of the queue: unstamped
        // they would head every sweep, and enough of them would fill the page.
        for (const userId of barred) {
            await recordState(admin, userId, "skipped by the sweep: not permitted, or the policy could not be read");
        }
    }
    const from = new Date(Date.now() - WINDOW_BEHIND_MS);
    const to = new Date(Date.now() + WINDOW_AHEAD_MS);

    let fetched = 0;
    let synced = 0;
    let failed = 0;
    let skipped = 0;

    // Concurrent in bounded chunks. Serially, each account is a round trip to
    // Google and back, and `invoke_internal_edge_job` gives the whole sweep 30
    // seconds — enough for a few dozen accounts before the caller stops waiting.
    for (let start = 0; start < permitted.length; start += CONCURRENCY) {
        const chunk = permitted.slice(start, start + CONCURRENCY);
        const results = await Promise.all(chunk.map(async (row) => {
            const userId = row.user_id as string;
            // One account's revoked grant or rate limit must not end the sweep
            // for everyone else in the chunk.
            try {
                // Claimed here as well: the app may have asked between the
                // listing and this chunk, and two reads of one calendar in the
                // same minute is exactly the spend this function exists to stop.
                const claim = await claimRead(admin, userId, SWEEP_STALE_SECONDS, MONTHLY_READ_CAP);
                if (claim !== "read") return { fetched: 0, stored: 0, skipped: true };
                const result = await syncAccount(
                    admin,
                    userId,
                    connectionFor(userId, row.broker_account_id as string),
                    from,
                    to,
                    "calendar-sweep",
                );
                return { ...result, skipped: false };
            } catch (cause) {
                const message = cause instanceof Error ? cause.message : String(cause);
                console.error(`calendar-sync failed for one account: ${message}`);
                await recordState(admin, userId, message);
                return null;
            }
        }));
        for (const result of results) {
            if (result === null) failed += 1;
            else if (result.skipped) skipped += 1;
            else {
                fetched += result.fetched;
                synced += result.stored;
            }
        }
    }

    // `fetched` and `stored` apart on purpose: without both, an empty calendar
    // and a calendar whose every entry we filtered out look identical.
    console.info(
        `calendar-sync sweep accounts=${permitted.length} fetched=${fetched} stored=${synced} failed=${failed} skipped=${skipped}`,
    );
    return json({ accounts: permitted.length, fetched, events: synced, failed, skipped }, 200);
}

function connectionFor(userId: string, brokerAccountID: string): Connection {
    return {
        id: brokerAccountID,
        provider: PROVIDER,
        externalUserId: userId,
        base: apiBase(PROVIDER) ?? "",
    };
}

type Claim = "read" | "floor" | "capped";

/// Takes the read if the floor has passed and the month's cap is not spent.
///
/// One statement in the database rather than a read-then-write here, because
/// the app and the sweep — or the same person's two Macs — can ask in the same
/// second, and the point of the floor is that only one of them pays. Null when
/// the database could not be asked, which the callers treat as a failure rather
/// than as permission.
async function claimRead(admin: Admin, userId: string, floorSeconds: number, cap: number | null): Promise<Claim | null> {
    const { data, error } = await admin.rpc("claim_calendar_read", {
        p_user: userId,
        p_provider: PROVIDER,
        p_calendar: CALENDAR_ID,
        p_floor_seconds: floorSeconds,
        p_monthly_cap: cap,
    });
    if (error) {
        console.error(`calendar-sync could not claim a read: ${error.message}`);
        return null;
    }
    return data === "read" || data === "floor" || data === "capped" ? data : null;
}

function startOfNextMonth(now: Date): Date {
    return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}

async function lastReadAt(admin: Admin, userId: string): Promise<string | null> {
    const { data } = await admin
        .from("calendar_sync_state")
        .select("synced_at")
        .eq("user_id", userId)
        .eq("provider", PROVIDER)
        .eq("calendar_id", CALENDAR_ID)
        .maybeSingle();
    const stamp = data?.synced_at as string | null | undefined;
    if (!stamp) return null;
    // Normalised to the shape the app parses: Postgres writes six fractional
    // digits and `+00:00`, the app's formatter reads three and `Z`.
    const parsed = new Date(stamp);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

async function syncAccount(
    admin: Admin,
    userId: string,
    connection: Connection,
    from: Date,
    to: Date,
    purpose: string,
): Promise<{ fetched: number; stored: number; syncedAt: string }> {
    // Stamped before the fetch, and the same value on every row, because the
    // prune below uses it as the cut-off: anything in the window still carrying
    // an older stamp is something the provider stopped returning.
    const stampedAt = new Date().toISOString();
    const events = await fetchWindow(connection, from, to, purpose);
    const rows = events
        .map((event) => toRow(userId, event, stampedAt))
        .filter((row): row is EventRow => row !== null);

    if (rows.length > 0) {
        const { error } = await admin
            .from("calendar_events")
            .upsert(rows, { onConflict: "user_id,calendar_id,external_event_id" });
        if (error) throw new Error(`upsert failed: ${error.message}`);
    }

    // Prune before the dual-write: a cancelled event must be gone from
    // source_objects before it can become a briefing candidate this cycle,
    // not tombstoned after the fact.
    await pruneWindow(admin, userId, from, to, stampedAt);

    // Dark until INGESTION_V2 is flipped (see context-platform-implementation
    // plan, Phase 4). Scoped to this user only — the global backfill already
    // caught everyone up once; a sync only needs to keep its own rows current.
    // Best-effort: the calendar row is already committed above, and a failure
    // here must not turn a successful sync into an error the caller retries.
    if (ingestionV2Enabled()) {
        const { error } = await admin.rpc("backfill_calendar_events_into_source_objects", { p_user_id: userId });
        if (error) console.error(`context-platform dual-write failed (non-fatal): ${error.message}`);
        else if (briefingsV1Enabled()) await generateUpcomingMeetingBriefings(admin, userId);
    }

    const syncedAt = await recordState(admin, userId, null);
    return { fetched: events.length, stored: rows.length, syncedAt };
}

// Phase 8 (minimal): for each of this user's upcoming calendar events that
// doesn't already have a ready briefing, try the deterministic prior-meeting
// linker; on a confident match, write one evidence-linked "last time"
// sentence. No match is the common, correct outcome today — see
// `link_prior_meeting_for_calendar_source_object`'s own comment for why it's
// conservative. Best-effort throughout: a briefing is a nice-to-have on top
// of a sync that has already committed its calendar rows, never something a
// failure here should turn into a sync error.
const BRIEFING_MODEL = Deno.env.get("BRIEFING_MODEL") ?? "anthropic/claude-haiku-4.5";
const BRIEFING_GENERATOR_VERSION = "context-platform-briefing-v1";

async function generateUpcomingMeetingBriefings(admin: Admin, userId: string): Promise<void> {
    const { data: pending, error } = await admin
        .from("source_objects")
        .select("id")
        .eq("user_id", userId)
        .eq("object_type", "google-calendar/event")
        .gte("occurred_at", new Date().toISOString())
        .is("deleted_at", null);
    if (error) {
        console.error(`briefing candidates lookup failed (non-fatal): ${error.message}`);
        return;
    }

    for (const row of pending ?? []) {
        try {
            await generateOneBriefing(admin, row.id as string);
        } catch (err) {
            console.error(`briefing generation failed for ${row.id} (non-fatal): ${String(err)}`);
        }
    }
}

// Below this, a match is a candidate per §7.3's own confidence policy
// ("may support retrieval but not autonomous mutation") -- rendering it as a
// flat, confident sentence on Home would overstate what the matcher actually
// knows. Only exact-identity matches (ical_uid/room_key, both 0.9+) generate
// visible text; weaker attendee-overlap matches still create a graph edge
// (useful for later retrieval) but stop here.
const MIN_BRIEFING_CONFIDENCE = 0.9;

async function generateOneBriefing(admin: Admin, calendarSourceObjectId: string): Promise<void> {
    const { data: fresh } = await admin.rpc(
        "has_fresh_upcoming_meeting_briefing",
        { p_calendar_source_object_id: calendarSourceObjectId },
    );
    if (fresh) return;

    const { data: edgeId, error: linkError } = await admin.rpc(
        "link_prior_meeting_for_calendar_source_object",
        { p_calendar_source_object_id: calendarSourceObjectId },
    );
    if (linkError || !edgeId) return;

    const { data: input, error: prepError } = await admin.rpc(
        "prepare_upcoming_meeting_briefing_input",
        { p_context_edge_id: edgeId },
    );
    if (prepError || !input || (input.match_confidence ?? 0) < MIN_BRIEFING_CONFIDENCE) return;

    const system = `You are writing one line for someone about to walk into a meeting with the same people again.

Say what was agreed last time and, if it changes the picture, what happened since, using the action counts given. One sentence, two only if the second genuinely adds something. Plain prose, not a list.

Ground every claim in the summary. Never invent a name, a number, or a decision that isn't there. Don't restate the counts as bare numbers -- say what they mean. Don't open with "Last time" or the meeting title. Respond with the sentence(s) only -- no quotes, no prefix, no markdown.`;
    const user = `[MEETING]\n${input.meeting_title ?? ""}\n\n[SUMMARY]\n${
        input.meeting_summary ?? ""
    }\n\n[ACTIONS FROM LAST TIME]\n${(input.actions_done ?? 0) + (input.actions_open ?? 0)} total -- ${
        input.actions_done ?? 0
    } done since, ${input.actions_open ?? 0} still open.\n\nWrite the sentence.`;

    const { data: userRow } = await admin
        .from("context_nodes")
        .select("user_id")
        .eq("id", input.calendar_node_id)
        .single();
    if (!userRow) return;

    const summary = await completeOnce({
        model: BRIEFING_MODEL,
        system,
        user,
        userId: userRow.user_id as string,
        task: "briefing",
        reasoningOff: true,
    });
    if (!summary) return;

    await admin.rpc("upsert_upcoming_meeting_briefing", {
        p_calendar_node_id: input.calendar_node_id,
        p_meeting_node_id: input.meeting_node_id,
        p_headline: input.meeting_title ?? "",
        p_summary: summary.trim(),
        p_confidence: input.match_confidence,
        p_generator_version: BRIEFING_GENERATOR_VERSION,
        p_evidence_ref_id: input.evidence_ref_id,
    });
}

/// Every page of the window. `singleEvents` expands a recurring series into the
/// instances it actually produces — without it a weekly standup is one row with
/// a recurrence rule, and nothing downstream could say which occurrence is now.
async function fetchWindow(connection: Connection, from: Date, to: Date, purpose: string): Promise<GoogleEvent[]> {
    const events: GoogleEvent[] = [];
    let pageToken: string | undefined;

    for (let page = 0; page < MAX_PAGES; page++) {
        const payload = await proxy(connection, EVENTS_PATH, null, {
            method: "GET",
            purpose,
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

/// Drops what the provider no longer returns for a window it was asked about.
///
/// By the run's own stamp rather than by listing what to keep: every row this
/// pass wrote carries `stampedAt`, so anything older inside the window is an
/// event that has moved or been cancelled. Naming the survivors instead meant
/// serialising up to 2 500 ids into the request — tens of kilobytes of URL, per
/// account, per read.
///
/// Scoped to the window on purpose: rows outside it are not evidence of
/// anything, and deleting on a wider net would clear a neighbouring window that
/// this call never looked at.
///
/// One RPC rather than a client-side delete: the matching source_objects row
/// (Phase 4 dual-write) must be tombstoned in the same statement that removes
/// the calendar_events row, or a cancelled event's stale copy lives on forever.
async function pruneWindow(
    admin: Admin,
    userId: string,
    from: Date,
    to: Date,
    stampedAt: string,
): Promise<void> {
    const { error } = await admin.rpc("prune_calendar_window", {
        p_user_id: userId,
        p_provider: PROVIDER,
        p_calendar_id: CALENDAR_ID,
        p_from: from.toISOString(),
        p_to: to.toISOString(),
        p_stamped_at: stampedAt,
    });
    if (error) console.error(`calendar-sync prune failed: ${error.message}`);
}

/// Stamps the read, succeeded or not. The stamp is what every floor is
/// measured from, so a calendar whose provider keeps refusing is retried no
/// faster than one that answers.
async function recordState(admin: Admin, userId: string, lastError: string | null): Promise<string> {
    const syncedAt = new Date().toISOString();
    const { error } = await admin
        .from("calendar_sync_state")
        .upsert({
            user_id: userId,
            provider: PROVIDER,
            calendar_id: CALENDAR_ID,
            synced_at: syncedAt,
            last_error: lastError,
        }, { onConflict: "user_id,provider,calendar_id" });
    if (error) console.error(`calendar-sync state write failed: ${error.message}`);
    return syncedAt;
}
