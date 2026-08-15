// Creating a calendar event on the user's own instruction.
//
// The only write Nod performs against a connected account. It exists because
// "set up a follow-up with Alina on Thursday" is the sentence people actually
// say after a meeting, and making them leave for a browser to act on it is where
// the follow-up dies.
//
// Reading is here as well as in the scheduled sync, because the two answer
// different questions: the sync keeps a rolling week on the device so the notch
// and the chat context are instant, while this reaches past that window when
// somebody asks about a date the device has never seen.
//
// Still no updating and no deleting. A tool that could delete would be a model
// one misunderstanding away from removing somebody's week.

import { ActionError, type Connection, proxy } from "./nango.ts";
import type { ActionHandlers } from "./registry.ts";

const EVENTS_PATH = "calendar/v3/calendars/primary/events";
const MAX_ATTENDEES = 20;

/// The slice of Google's event resource anything in Nod reads. One declaration
/// for the two callers — the scheduled sync and the chat's read tool — because
/// a field added for one of them is a field the other silently keeps missing.
export interface GoogleEvent {
    id?: string;
    iCalUID?: string;
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

function requireString(params: Record<string, unknown>, key: string): string {
    const value = params[key];
    if (typeof value !== "string" || value.trim() === "") {
        throw new ActionError("invalid_params", `\`${key}\` is required.`);
    }
    return value.trim();
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
                title: event.summary ?? "(no title)",
                starts_at: event.start?.dateTime ?? event.start?.date ?? null,
                ends_at: event.end?.dateTime ?? event.end?.date ?? null,
                // An all-day entry carries a date rather than an instant, and
                // reading it as a time would put a birthday at midnight.
                all_day: event.start?.date !== undefined,
                location: event.location ?? null,
                conference_url: event.hangoutLink ?? null,
                attendees: (event.attendees ?? [])
                    .filter((attendee) => !attendee.resource && attendee.email)
                    .map((attendee) => attendee.displayName?.trim() || attendee.email),
            })),
        };
    },

    /// Creates one event and invites the addresses given.
    ///
    /// `sendUpdates=all` is why the desktop side shows the draft first and waits
    /// for a person to press the button: this call puts mail in other people's
    /// inboxes and an entry in their calendars, and neither can be recalled.
    create_event: async (connection, params) => {
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
        }) as {
            id?: string;
            htmlLink?: string;
            hangoutLink?: string;
            start?: { dateTime?: string };
        } | null;

        if (!created?.id) {
            throw new ActionError("provider_error", "Google did not return the created event.", 502);
        }
        return {
            id: created.id,
            url: created.htmlLink ?? null,
            conference_url: created.hangoutLink ?? null,
            starts_at: created.start?.dateTime ?? start,
            invited: attendees.map((attendee) => attendee.email),
        };
    },
};
