// Creating a calendar event on the user's own instruction.
//
// The only write Nod performs against a connected account. It exists because
// "set up a follow-up with Alina on Thursday" is the sentence people actually
// say after a meeting, and making them leave for a browser to act on it is where
// the follow-up dies.
//
// Deliberately one action, not a calendar API. No updating, no deleting, no
// reading — the sync already reads, on a schedule, with the service role. A tool
// that could delete would be a model one misunderstanding away from removing
// somebody's week.

import { ActionError, type Connection, proxy } from "./nango.ts";
import type { ActionHandlers } from "./registry.ts";

const EVENTS_PATH = "calendar/v3/calendars/primary/events";
const MAX_ATTENDEES = 20;

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

export const GOOGLE_CALENDAR_ACTIONS: ActionHandlers = {
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
