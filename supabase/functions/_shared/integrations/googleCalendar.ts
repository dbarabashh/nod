// Acting in the user's calendar on their own instruction.
//
// The writes exist because "set up a follow-up with Alina on Thursday" — and
// "move it to Friday", and "cancel it" — are the sentences people actually say
// after a meeting, and making them leave for a browser to act on them is where
// the follow-up dies.
//
// Reading is here as well as in the scheduled sync, because the two answer
// different questions: the sync keeps a rolling week on the device so the notch
// and the chat context are instant, while this reaches past that window when
// somebody asks about a date the device has never seen.
//
// Every write stops at the desktop's approval card, and the two destructive
// ones are held to the title the person read there — see `confirmedEvent`,
// which is what keeps one misunderstanding from removing somebody's week.

import { ActionError, proxy } from "./pipedream.ts";
import { adminClient } from "../supabase.ts";
import type { ActionContext, ActionHandlers } from "./registry.ts";
import { requireList, requireString } from "./params.ts";

const EVENTS_PATH = "calendar/v3/calendars/primary/events";
const MAX_ATTENDEES = 20;

export const PROVIDER = "google-calendar";
export const CALENDAR_ID = "primary";

/// One Google event as `calendar_events` stores it.
export interface EventRow {
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

/// One Google event as we store it, or null for one we have no use for.
///
/// All-day entries are dropped: a birthday or a leave day has no start time to
/// match a recording against, and keeping them would mean storing more of
/// somebody's private calendar than the feature can ever read.
///
/// Lives here rather than in `calendar-sync` because there are now two writers —
/// the ten-minute sweep and the event this adapter has just created — and two
/// mappings of one provider's shape is how the row a sweep writes and the row a
/// creation writes start disagreeing about the same meeting.
export function toRow(userId: string, event: GoogleEvent, stampedAt: string): EventRow | null {
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
        attendees: attendeesFrom(event),
        updated_at: stampedAt,
    };
}

/// Where the meeting actually happens. `hangoutLink` is Google's own shortcut
/// and is present for a Meet link; `conferenceData` is the general form and
/// carries Zoom and Teams when the organizer added one.
export function conferenceURL(event: GoogleEvent): string | null {
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
export function attendeesFrom(event: GoogleEvent): Array<{ email: string; display?: string; response: string }> {
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

/// The slice of Google's event resource anything in Nod reads. One declaration
/// for the two callers — the scheduled sync and the chat's read tool — because
/// a field added for one of them is a field the other silently keeps missing.
export interface GoogleEvent {
    id?: string;
    etag?: string;
    iCalUID?: string;
    recurringEventId?: string;
    recurrence?: string[];
    summary?: string;
    status?: string;
    location?: string;
    hangoutLink?: string;
    start?: { dateTime?: string; date?: string };
    end?: { dateTime?: string; date?: string };
    organizer?: { email?: string };
    attendees?: Array<{ email?: string; displayName?: string; responseStatus?: string; resource?: boolean }>;
    conferenceData?: { entryPoints?: Array<{ entryPointType?: string; uri?: string }> };
}


/// An RFC3339 instant. The client sends absolute times — it holds the user's
/// clock and their calendar's timezone, and a server guessing either would put
/// the meeting an hour out for exactly the people who travel.
function requireInstant(params: Record<string, unknown>, key: string): string {
    const raw = requireString(params, key);
    const parsed = Date.parse(raw);
    if (Number.isNaN(parsed)) {
        throw new ActionError("invalid_params", `\`${key}\` must be an RFC3339 timestamp.`);
    }
    return new Date(parsed).toISOString();
}

function attendeesOf(params: Record<string, unknown>): Array<{ email: string }> {
    const raw = params.attendees;
    const list = typeof raw === "string"
        ? raw.split(",").map((entry) => entry.trim()).filter(Boolean)
        : Array.isArray(raw)
        ? raw.map((entry) => String(entry).trim()).filter(Boolean)
        : [];
    if (list.length > MAX_ATTENDEES) {
        throw new ActionError("invalid_params", `At most ${MAX_ATTENDEES} attendees per event.`);
    }
    for (const email of list) {
        if (!email.includes("@") || email.includes(" ")) {
            throw new ActionError("invalid_params", `"${email}" is not an email address.`);
        }
    }
    return list.map((email) => ({ email }));
}

function eventPath(id: string): string {
    return `${EVENTS_PATH}/${encodeURIComponent(id)}`;
}

/// Whether the title the person confirmed is the title the id points at.
///
/// An untitled event is listed as "(no title)", so that is also the words a
/// person approves for one — without this, an untitled event could never be
/// acted on, and the "list again" hint would loop forever.
export function titleMatches(expected: string, summary: string | null | undefined): boolean {
    const actual = (summary ?? "").trim().toLowerCase();
    const wanted = expected.trim().toLowerCase();
    return actual === wanted || (actual === "" && wanted === "(no title)");
}

/// The event `event_id` names, checked against the title and start the person
/// approved.
///
/// The card shows words while the wire carries an id, and this is what keeps a
/// model from pairing the right words with the wrong event. The title alone
/// cannot: every occurrence of a recurring meeting shares it, so the start time
/// is what separates Thursday's standup from Tuesday's. A cancelled event is
/// refused too: updating one resurrects it, and deleting one implies to the
/// person that it was still standing.
async function confirmedEvent(
    connection: Parameters<typeof proxy>[0],
    params: Record<string, unknown>,
): Promise<GoogleEvent> {
    const id = requireString(params, "event_id");
    const expectedTitle = requireString(params, "event_title");
    const expectedStart = requireString(params, "event_starts_at");

    const event = await proxy(connection, eventPath(id), null, { method: "GET" }) as GoogleEvent | null;
    if (!event?.id) {
        throw new ActionError("provider_error", "Google did not return that event.", 502);
    }
    if (event.status === "cancelled") {
        throw new ActionError("invalid_params", "That event is already cancelled.");
    }
    // A series master. `list_events` can never return one (`singleEvents`
    // expands them), so this id was shortened by hand — and acting on it would
    // hit every occurrence when the person approved what read as one.
    if (event.recurrence !== undefined) {
        throw new ActionError(
            "invalid_params",
            "That id names a whole recurring series. List events and use the id of the one occurrence meant.",
        );
    }
    const relist = "List events again and use the id, title and start shown next to the right event.";
    if (!titleMatches(expectedTitle, event.summary)) {
        const summary = event.summary?.trim();
        const actual = summary ? `"${summary}"` : "untitled";
        throw new ActionError("invalid_params", `That event is ${actual}, not "${expectedTitle}". ${relist}`);
    }
    if (!startMatches(expectedStart, event)) {
        const actual = event.start?.dateTime ?? event.start?.date ?? "unknown";
        throw new ActionError("invalid_params", `That event starts at ${actual}, not ${expectedStart}. ${relist}`);
    }
    return event;
}

/// Whether the start the person approved is the start the id points at. An
/// all-day event carries a date rather than an instant, and is matched on it.
export function startMatches(expected: string, event: GoogleEvent): boolean {
    if (event.start?.date) return expected.trim() === event.start.date;
    const actual = event.start?.dateTime;
    if (!actual) return false;
    const wanted = Date.parse(expected);
    return !Number.isNaN(wanted) && wanted === Date.parse(actual);
}

const MAX_RESULTS = 25;

export const GOOGLE_CALENDAR_ACTIONS: ActionHandlers = {
    /// Lists events in a window, expanded so a recurring meeting comes back as
    /// the occurrence that falls inside it rather than as its rule.
    list_events: async (connection, params) => {
        const start = requireInstant(params, "starts_at");
        const end = requireInstant(params, "ends_at");
        if (Date.parse(end) <= Date.parse(start)) {
            throw new ActionError("invalid_params", "`ends_at` must be after `starts_at`.");
        }

        const listed = await proxy(connection, EVENTS_PATH, null, {
            method: "GET",
            query: {
                timeMin: start,
                timeMax: end,
                singleEvents: "true",
                orderBy: "startTime",
                maxResults: String(MAX_RESULTS),
            },
        }) as { items?: GoogleEvent[] } | null;

        // Cancelled occurrences of a recurring event come back in the list and
        // are not meetings — the user declined or the organizer called it off.
        const events = (listed?.items ?? []).filter((event) => event.status !== "cancelled");
        return {
            events: events.map((event) => ({
                id: event.id ?? null,
                title: event.summary ?? "(no title)",
                starts_at: event.start?.dateTime ?? event.start?.date ?? null,
                ends_at: event.end?.dateTime ?? event.end?.date ?? null,
                // An all-day entry carries a date rather than an instant, and
                // reading it as a time would put a birthday at midnight.
                all_day: event.start?.date !== undefined,
                location: event.location ?? null,
                conference_url: event.hangoutLink ?? null,
                // Name and address both: the name is what a person means,
                // the address is what update_event's guest edits take.
                attendees: (event.attendees ?? [])
                    .filter((attendee) => !attendee.resource && attendee.email)
                    .map((attendee) => {
                        const display = attendee.displayName?.trim();
                        return display ? `${display} <${attendee.email}>` : attendee.email;
                    }),
            })),
        };
    },

    /// Creates one event and invites the addresses given.
    ///
    /// `sendUpdates=all` is why the desktop side shows the draft first and waits
    /// for a person to press the button: this call puts mail in other people's
    /// inboxes and an entry in their calendars, and neither can be recalled.
    create_event: async (connection, params, context) => {
        const summary = requireString(params, "title");
        const start = requireInstant(params, "starts_at");
        const end = requireInstant(params, "ends_at");
        if (Date.parse(end) <= Date.parse(start)) {
            throw new ActionError("invalid_params", "`ends_at` must be after `starts_at`.");
        }
        const attendees = attendeesOf(params);
        const description = typeof params.description === "string" ? params.description : undefined;
        // A meeting with people in it gets a room, because an invitation without
        // one is a calendar entry rather than a call.
        const wantsRoom = attendees.length > 0 && params.conferencing !== false;

        const created = await proxy(connection, EVENTS_PATH, {
            summary,
            description,
            start: { dateTime: start },
            end: { dateTime: end },
            attendees,
            ...(wantsRoom
                ? {
                    conferenceData: {
                        createRequest: {
                            requestId: crypto.randomUUID(),
                            conferenceSolutionKey: { type: "hangoutsMeet" },
                        },
                    },
                }
                : {}),
        }, {
            method: "POST",
            query: {
                sendUpdates: "all",
                conferenceDataVersion: wantsRoom ? "1" : "0",
            },
        }) as GoogleEvent & { htmlLink?: string } | null;

        if (!created?.id) {
            throw new ActionError("provider_error", "Google did not return the created event.", 502);
        }

        await cache(created as GoogleEvent, context, { colleagues: true });

        return {
            id: created.id,
            url: created.htmlLink ?? null,
            conference_url: created.hangoutLink ?? null,
            starts_at: created.start?.dateTime ?? start,
            invited: attendees.map((attendee) => attendee.email),
        };
    },

    /// Changes one event the person confirmed by title and start.
    /// `sendUpdates=all` again: a moved meeting the guests were not told about
    /// is a meeting they miss.
    ///
    /// Guests are edited as deltas, never as a replacement list. A replacement
    /// would have to be assembled by the model from a listing, and one address
    /// it left out would be a person silently uninvited; a delta can only do
    /// what it says. The merge also keeps each remaining guest's RSVP, which a
    /// rewritten list would reset.
    update_event: async (connection, params, context) => {
        const event = await confirmedEvent(connection, params);

        const patch: Record<string, unknown> = {};
        if (params.new_title !== undefined) {
            patch.summary = requireString(params, "new_title");
        }
        if (params.description !== undefined) {
            if (typeof params.description !== "string") {
                throw new ActionError("invalid_params", "`description` must be a string.");
            }
            patch.description = params.description;
        }
        if ((params.starts_at === undefined) !== (params.ends_at === undefined)) {
            throw new ActionError("invalid_params", "Move `starts_at` and `ends_at` together.");
        }
        if (params.starts_at !== undefined) {
            if (event.start?.date) {
                throw new ActionError("invalid_params", "That is an all-day entry; it has no time to move.");
            }
            const start = requireInstant(params, "starts_at");
            const end = requireInstant(params, "ends_at");
            if (Date.parse(end) <= Date.parse(start)) {
                throw new ActionError("invalid_params", "`ends_at` must be after `starts_at`.");
            }
            patch.start = { dateTime: start };
            patch.end = { dateTime: end };
        }
        const guests = guestEdits(params, event);
        if (guests) patch.attendees = guests;
        if (Object.keys(patch).length === 0) {
            throw new ActionError(
                "invalid_params",
                "Nothing to change — pass `new_title`, `starts_at`/`ends_at`, `description`, `add_attendees`, or `remove_attendees`.",
            );
        }

        const updated = await proxy(connection, eventPath(event.id as string), patch, {
            method: "PATCH",
            query: { sendUpdates: "all" },
            ...(event.etag ? { headers: { "If-Match": event.etag } } : {}),
        }) as GoogleEvent & { htmlLink?: string } | null;

        if (!updated?.id) {
            throw new ActionError("provider_error", "Google did not return the updated event.", 502);
        }

        await cache(updated as GoogleEvent, context, { colleagues: false });

        return {
            id: updated.id,
            url: updated.htmlLink ?? null,
            title: updated.summary ?? null,
            starts_at: updated.start?.dateTime ?? null,
            ends_at: updated.end?.dateTime ?? null,
            attendees: (updated.attendees ?? [])
                .filter((attendee) => attendee.email && !attendee.resource)
                .map((attendee) => attendee.email),
            ...occurrenceScope(event),
        };
    },

    /// Removes one event the person confirmed by title and start. Google mails
    /// the guests the cancellation; an attendee without delete rights only
    /// leaves their own copy, which is Google's rule, not a choice made here.
    delete_event: async (connection, params, context) => {
        const event = await confirmedEvent(connection, params);

        await proxy(connection, eventPath(event.id as string), undefined, {
            method: "DELETE",
            query: { sendUpdates: "all" },
            ...(event.etag ? { headers: { "If-Match": event.etag } } : {}),
        });

        await forget(event.id as string, context);

        return { id: event.id, title: event.summary ?? null, deleted: true, ...occurrenceScope(event) };
    },
};

/// Says when an action landed on one occurrence of a recurring meeting rather
/// than the series — with `singleEvents` listing, an occurrence is the only
/// thing an id can ever name, and a person told "cancelled" about a weekly
/// meeting will otherwise be surprised next week.
function occurrenceScope(event: GoogleEvent): Record<string, string> {
    return event.recurringEventId
        ? { scope: "one occurrence of a recurring meeting — the other occurrences still stand" }
        : {};
}

/// The guest list after the asked-for additions and removals, or null when
/// neither was asked for. Built on the live list so everyone not named keeps
/// their place and their RSVP.
function guestEdits(params: Record<string, unknown>, event: GoogleEvent): Array<Record<string, unknown>> | null {
    if (params.add_attendees === undefined && params.remove_attendees === undefined) return null;

    const additions = params.add_attendees === undefined
        ? []
        : requireList(params, "add_attendees", MAX_ATTENDEES);
    const removals = params.remove_attendees === undefined
        ? []
        : requireList(params, "remove_attendees", MAX_ATTENDEES).map((email) => email.toLowerCase());
    for (const email of [...additions, ...removals]) {
        if (!email.includes("@") || email.includes(" ")) {
            throw new ActionError("invalid_params", `"${email}" is not an email address.`);
        }
    }

    const current = (event.attendees ?? []).filter((attendee) => attendee.email);
    const missing = removals.filter((email) =>
        !current.some((attendee) => (attendee.email as string).toLowerCase() === email)
    );
    if (missing.length > 0) {
        throw new ActionError("invalid_params", `${missing.join(", ")} is not on the guest list.`);
    }

    const kept = current.filter((attendee) =>
        !removals.includes((attendee.email as string).toLowerCase())
    ) as Array<Record<string, unknown>>;
    const seen = new Set(kept.map((attendee) => (attendee.email as string).toLowerCase()));
    const added: Array<Record<string, unknown>> = [];
    for (const email of additions) {
        if (seen.has(email.toLowerCase())) continue;
        seen.add(email.toLowerCase());
        added.push({ email });
    }

    const list = [...kept, ...added];
    // The cap applies to growth only. An event that arrived from outside Nod
    // already over the cap must still allow a removal — refusing it would make
    // the largest guest lists the only ones nobody can take a name off.
    if (list.length > MAX_ATTENDEES && added.length > 0) {
        throw new ActionError("invalid_params", `At most ${MAX_ATTENDEES} attendees per event.`);
    }
    return list;
}

/// Drops a deleted event from the deleter's own `calendar_events` rows without
/// waiting for the sweep.
///
/// The deleter's rows only. Whether anyone else's copy of the meeting still
/// stands is Google's call, not this function's — an attendee's delete leaves
/// the meeting running for everyone but them — and colleagues' rows are theirs:
/// their own sweeps prune what Google stops listing. Best-effort for the same
/// reason `cache` is — the event is gone in Google whatever happens here, and
/// the sweep remains the backstop.
async function forget(externalEventId: string, context?: ActionContext): Promise<void> {
    if (!context?.userId) return;
    try {
        const { error } = await adminClient()
            .from("calendar_events")
            .delete()
            .eq("user_id", context.userId)
            .eq("provider", PROVIDER)
            .eq("calendar_id", CALENDAR_ID)
            .eq("external_event_id", externalEventId);
        if (error) console.warn(`calendar cache delete failed: ${error.message}`);
    } catch (error) {
        console.warn(`calendar cache delete threw: ${error}`);
    }
}

/// Writes an event we just created straight into `calendar_events`.
///
/// The scheduled sweep would find it on its own — in up to ten minutes. That is
/// too late by construction: `ScheduledMeeting` offers to record from sixty
/// seconds before a meeting until three minutes after it starts, so a four
/// minute window sits entirely inside one sync interval. Ask Nod for a meeting
/// "in the next three minutes" and the sweep lands the row at roughly the moment
/// the window shuts — for the organizer and, worse, for everyone invited, who
/// had no other way to know. Observed on 2026-08-16: event created 20:24 UTC to
/// start 20:27, still absent at 20:29:44, next sweep 20:30.
///
/// Best-effort on purpose. The meeting exists in Google whatever happens here,
/// and failing the tool call — after invitations have already gone out — because
/// our own cache write failed would turn a cosmetic problem into a real one. The
/// sweep remains the backstop.
///
/// Written for the caller and for the colleagues they invited, because the gap
/// this closes is on both sides. Two people can only be shown as being in one
/// meeting when both of their rows exist — the host's lease takes its identity
/// from theirs, and the listener asks with theirs — so caching only the
/// organizer's copy would leave the invitee exactly as blind as before.
/// `colleagues` is true only for creation, where the invitee has no row at all
/// yet. On an update every synced colleague already holds a real copy under
/// their own id, and writing a provisional row beside it would show them the
/// same meeting twice — with two different times — until their sweep prunes it.
async function cache(
    event: GoogleEvent,
    context: ActionContext | undefined,
    options: { colleagues: boolean },
): Promise<void> {
    if (!context?.userId) return;
    const stampedAt = new Date().toISOString();
    const own = toRow(context.userId, event, stampedAt);
    if (!own) return;

    const admin = adminClient();
    const rows = options.colleagues
        ? [own, ...await invitedColleagueRows(admin, event, context.userId, stampedAt)]
        : [own];

    try {
        const { error } = await admin
            .from("calendar_events")
            .upsert(rows, { onConflict: "user_id,calendar_id,external_event_id" });
        if (error) {
            console.warn(`calendar cache write failed: ${error.message}`);
            return;
        }
        console.info(`calendar cache: stored the created event for ${rows.length} calendar(s)`);
    } catch (error) {
        console.warn(`calendar cache write threw: ${error}`);
    }
}

/// Provisional rows for the colleagues this event invited.
///
/// Each carries the *organizer's* `external_event_id`, because that is the only
/// id this response has — Google gives every attendee a different one. That
/// costs nothing: no read path uses it. Matching one meeting across two people
/// is done on `ical_uid`, which every copy shares by construction (RFC 5545),
/// and the id here is only the upsert key. When the invitee's own sweep runs it
/// writes their real copy and prunes this one, because the prune drops anything
/// in the window still carrying an older stamp. So the row is a ten-minute
/// stand-in that cleans itself up.
///
/// Narrow on purpose: colleagues in the organizer's own organization, who have
/// a Nod account, who already have their calendar connected — which means Nod
/// was going to write this exact row for them anyway, minutes later. It is the
/// timing that changes, not what anybody gets to see.
async function invitedColleagueRows(
    admin: ReturnType<typeof adminClient>,
    event: GoogleEvent,
    organizerId: string,
    stampedAt: string,
): Promise<EventRow[]> {
    const invited = (event.attendees ?? [])
        .filter((attendee) => attendee.email && !attendee.resource)
        .map((attendee) => (attendee.email as string).toLowerCase());
    if (invited.length === 0) return [];

    try {
        const { data: profile } = await admin
            .from("profiles")
            .select("active_org_id")
            .eq("user_id", organizerId)
            .maybeSingle<{ active_org_id: string | null }>();
        const orgId = profile?.active_org_id;
        if (!orgId) return [];

        const { data: people } = await admin
            .from("people")
            .select("user_id, primary_email")
            .eq("org_id", orgId)
            .not("user_id", "is", null)
            .is("deleted_at", null);

        const colleagues = (people ?? [])
            .filter((person) =>
                person.primary_email && invited.includes(String(person.primary_email).toLowerCase())
            )
            .map((person) => person.user_id as string)
            .filter((userId) => userId !== organizerId);
        if (colleagues.length === 0) return [];

        // Only those already syncing a calendar. Writing a row for somebody who
        // never connected one would put an event in a table nothing of theirs
        // maintains, and nothing would ever clean it up.
        const { data: connected } = await admin
            .from("integration_connections")
            .select("user_id")
            .eq("provider", PROVIDER)
            .is("revoked_at", null)
            .in("user_id", colleagues);

        return (connected ?? [])
            .map((row) => toRow(row.user_id as string, event, stampedAt))
            .filter((row): row is EventRow => row !== null);
    } catch (error) {
        console.warn(`calendar cache: could not resolve invited colleagues — ${error}`);
        return [];
    }
}
