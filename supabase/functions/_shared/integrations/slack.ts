// Slack, over its Web API.
//
// The first provider where the identity work is not an optimisation but the
// whole feature: "create a channel for the migration and add Anna, Alex and
// John" cannot be carried out from three first names. Every member action here
// takes Slack member ids, resolved from `people` by the executor, and this file
// never sees a name it has to guess about.
//
// Reads and additive writes, and nothing else. Creating a channel and inviting
// colleagues are visible and reversible — everybody invited can see what
// happened and leave — and reading answers a question from what the team
// already said. Posting messages, archiving channels and removing members are
// none of those things, and none of them is needed to turn a meeting into work.
//
// Reading a public channel means joining it, because Slack gives a bot no other
// way in. That is the one read here that leaves a trace, and the trace is a
// "Nod joined" line the whole channel can see.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

/// Slack answers 200 with `{ ok: false, error: "…" }`, so the transport being
/// fine says nothing about the call.
async function call(
    connection: Connection,
    method: string,
    body: Record<string, unknown>,
    options: { method?: "GET" | "POST"; query?: Record<string, string | undefined> } = {},
): Promise<Record<string, unknown>> {
    const payload = await proxy(connection, method, body, options) as
        | { ok?: boolean; error?: string }
        | null;

    if (!payload?.ok) {
        const detail = payload?.error ?? "unknown_error";
        throw new ActionError(SLACK_ERRORS[detail] ?? "provider_error", messageFor(detail), 502, detail);
    }
    return payload as Record<string, unknown>;
}

/// Slack's error strings, mapped to codes a caller can act on. Anything absent
/// stays `provider_error`, which the review card renders as a plain failure.
const SLACK_ERRORS: Record<string, string> = {
    name_taken: "name_taken",
    invalid_name_specials: "invalid_params",
    invalid_name_maxlength: "invalid_params",
    missing_scope: "reauthorize",
    not_authed: "reauthorize",
    invalid_auth: "reauthorize",
    account_inactive: "reauthorize",
    restricted_action: "not_permitted",
};

function messageFor(error: string): string {
    switch (error) {
        case "name_taken":
            return "A Slack channel with that name already exists.";
        case "missing_scope":
        case "not_authed":
        case "invalid_auth":
        case "account_inactive":
            return "Nod's Slack access needs to be reconnected in Settings → Integrations.";
        case "restricted_action":
            return "This Slack workspace does not allow that.";
        case "cant_invite_self":
            return "Nod cannot invite itself to a channel.";
        default:
            return `Slack rejected the request: ${error}.`;
    }
}


/// Slack channel names: lowercase, no spaces or dots, 80 characters.
///
/// Normalised rather than rejected, because a model asked for a channel name
/// after a conversation about "Auth Migration" writes `Auth Migration`, and
/// failing on it would put a formatting rule in front of a person who typed
/// nothing wrong.
function channelName(raw: string): string {
    const name = raw
        .toLowerCase()
        .replace(/^#/, "")
        .replace(/[^a-z0-9_-]+/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "")
        .slice(0, 80);
    if (!name) {
        throw new ActionError("invalid_params", `"${raw}" leaves no usable Slack channel name.`);
    }
    return name;
}

const MAX_INVITES = 50;

function memberIDs(params: Record<string, unknown>, key: string): string[] {
    const raw = params[key];
    const list = typeof raw === "string"
        ? raw.split(",").map((entry) => entry.trim()).filter(Boolean)
        : Array.isArray(raw)
        ? raw.map((entry) => String(entry).trim()).filter(Boolean)
        : [];
    if (list.length > MAX_INVITES) {
        throw new ActionError("invalid_params", `At most ${MAX_INVITES} people per invitation.`);
    }
    // Member ids, never names or addresses. Anything else reaching this point
    // means the executor failed to resolve somebody and the call must not go
    // ahead with a string Slack would either reject or, worse, match loosely.
    for (const id of list) {
        if (!/^[UW][A-Z0-9]{2,}$/.test(id)) {
            throw new ActionError("unresolved_person", `"${id}" is not a Slack member id.`);
        }
    }
    return list;
}

/// Everybody a call is meant to invite, as Slack member ids.
///
/// Two ways in, because there are two callers and they know different things. A
/// proposal raised from a meeting carries `people` rows, already resolved to
/// member ids by the executor. The chat carries addresses — it has the
/// organization directory in its prompt and no way to learn a Slack id — exactly
/// as `google-calendar.create_event` already takes addresses for its guests.
///
/// Both end in member ids before anything is invited. An address that matches
/// nobody in the workspace is an error and not a silent omission: "add Anna,
/// Alex and John" that quietly adds two of them is worse than one that fails.
async function invitees(connection: Connection, params: Record<string, unknown>): Promise<string[]> {
    const ids = memberIDs(params, "invite_member_ids");
    const emails = list(params, "invite_emails");
    if (emails.length === 0) return ids;
    if (ids.length + emails.length > MAX_INVITES) {
        throw new ActionError("invalid_params", `At most ${MAX_INVITES} people per invitation.`);
    }

    const resolved: string[] = [];
    for (const email of emails) {
        if (!email.includes("@")) {
            throw new ActionError("invalid_params", `"${email}" is not an email address.`);
        }
        const payload = await call(connection, "users.lookupByEmail", {}, {
            method: "GET",
            query: { email },
        }).catch(() => null);
        const user = payload?.user as { id?: string } | undefined;
        if (!user?.id) {
            throw new ActionError("unresolved_person", `Nobody in this Slack workspace uses ${email}.`);
        }
        resolved.push(user.id);
    }
    return [...new Set([...ids, ...resolved])];
}

function list(params: Record<string, unknown>, key: string): string[] {
    const raw = params[key];
    if (typeof raw === "string") return raw.split(",").map((entry) => entry.trim()).filter(Boolean);
    if (Array.isArray(raw)) return raw.map((entry) => String(entry).trim()).filter(Boolean);
    return [];
}

/// A channel's messages, letting Nod in first if it isn't a member yet.
///
/// Slack gives a bot no way to read a public channel it hasn't joined, and no
/// scope changes that — so the choice is between joining and not answering.
/// Joining is visible: the channel gets a "Nod joined" line, which is the right
/// trade only because the alternative is a product that quietly cannot see the
/// room it was asked about. A private channel has no such door, and its
/// `not_in_channel` is passed on as the failure it is.
async function history(
    connection: Connection,
    channel: string,
    limit: number,
): Promise<Record<string, unknown>> {
    const read = () =>
        call(connection, "conversations.history", {}, {
            method: "GET",
            query: { channel, limit: String(limit) },
        });
    try {
        return await read();
    } catch (error) {
        if (!(error instanceof ActionError) || error.providerCode !== "not_in_channel") throw error;
        await call(connection, "conversations.join", { channel });
        return await read();
    }
}

/// Slack stamps a message with a unix time and a sequence, as `1723989000.123`.
/// The model reads dates, not epochs.
function slackTimestamp(ts: string | undefined): string {
    const seconds = Number((ts ?? "").split(".")[0]);
    if (!Number.isFinite(seconds) || seconds <= 0) return "";
    return new Date(seconds * 1000).toISOString();
}

/// One member of the workspace, as both readers of `users.list` need them.
interface SlackMember {
    id: string;
    deleted?: boolean;
    is_bot?: boolean;
    real_name?: string;
    profile?: { email?: string; real_name?: string; display_name?: string };
}

/// The workspace's roster, fetched at most once a minute per connection.
///
/// Two callers want it for different reasons — the directory import wants
/// addresses, a channel read wants names to put beside quotes — and a single
/// question can read a channel and then two of its threads. Fetched per call
/// that was one full roster download each, against the same rate limit the
/// directory import needs; the identical payload answers all of them.
const rosters = new Map<string, { members: SlackMember[]; until: number }>();
const ROSTER_TTL_MS = 60_000;

async function workspaceMembers(connection: Connection): Promise<SlackMember[]> {
    const cached = rosters.get(connection.id);
    if (cached && cached.until > Date.now()) return cached.members;

    const payload = await call(connection, "users.list", {}, {
        method: "GET",
        query: { limit: "500" },
    });
    const members = (payload.members as SlackMember[] | undefined) ?? [];
    rosters.set(connection.id, { members, until: Date.now() + ROSTER_TTL_MS });
    return members;
}

/// User ids to the names a person would recognise. Anything the roster doesn't
/// answer for keeps its id rather than becoming "someone" — a name Nod cannot
/// resolve is still a distinct speaker, and collapsing several of them into one
/// word makes a conversation read as if one person said everything.
async function displayNames(
    connection: Connection,
    ids: (string | undefined)[],
): Promise<Record<string, string>> {
    const wanted = new Set(ids.filter((id): id is string => Boolean(id)));
    if (wanted.size === 0) return {};

    const members = await workspaceMembers(connection).catch(() => [] as SlackMember[]);
    const names: Record<string, string> = {};
    for (const member of members) {
        if (!wanted.has(member.id)) continue;
        names[member.id] = member.profile?.display_name || member.profile?.real_name || member.real_name || member.id;
    }
    return names;
}

export const SLACK_ACTIONS: ActionHandlers = {
    /// Every channel Nod can reach: all public ones, plus the private channels
    /// somebody added it to.
    ///
    /// Public channels are listed whether or not Nod is in them, because it can
    /// let itself in — `read_channel` joins on demand. Private ones are only
    /// here when it was invited, since no scope lets a bot into a private
    /// channel on its own; listing those would offer the model a door it cannot
    /// open.
    list_channels: async (connection, params) => {
        const query = typeof params?.query === "string" ? params.query.toLowerCase().trim() : "";
        const payload = await call(connection, "conversations.list", {}, {
            method: "GET",
            query: {
                types: "public_channel,private_channel",
                exclude_archived: "true",
                limit: "200",
            },
        });
        const channels = (payload.channels as {
            id: string;
            name?: string;
            is_member?: boolean;
            is_private?: boolean;
            is_archived?: boolean;
            topic?: { value?: string };
            purpose?: { value?: string };
        }[] | undefined) ?? [];

        return {
            channels: channels
                .filter((channel) => channel.is_member || !channel.is_private)
                .filter((channel) =>
                    !query ||
                    (channel.name ?? "").toLowerCase().includes(query) ||
                    (channel.purpose?.value ?? "").toLowerCase().includes(query)
                )
                .slice(0, 60)
                .map((channel) => ({
                    id: channel.id,
                    name: channel.name ?? channel.id,
                    purpose: channel.purpose?.value || channel.topic?.value || "",
                    joined: channel.is_member === true,
                })),
        };
    },

    /// What was said in one channel, newest first.
    ///
    /// Names are resolved here rather than handed back as `U0123ABCD`: the model
    /// is being asked what a team decided, and an answer attributing it to a
    /// user id is unreadable to the person who asked. Bot posts are dropped —
    /// deploy notifications are not what anybody means by "what did we say".
    read_channel: async (connection, params) => {
        const channel = requireString(params, "channel");
        const limit = Math.min(Math.max(Number(params?.limit ?? 50), 1), 200);
        const payload = await history(connection, channel, limit);
        const messages = (payload.messages as {
            type?: string;
            subtype?: string;
            user?: string;
            bot_id?: string;
            text?: string;
            ts?: string;
            thread_ts?: string;
            reply_count?: number;
        }[] | undefined) ?? [];

        const said = messages.filter((message) =>
            message.type === "message" && !message.bot_id && !message.subtype && (message.text ?? "").trim()
        );
        const names = await displayNames(connection, said.map((message) => message.user));

        return {
            messages: said.map((message) => ({
                author: names[message.user ?? ""] ?? message.user ?? "someone",
                text: message.text ?? "",
                at: slackTimestamp(message.ts),
                thread: message.thread_ts && message.reply_count ? message.thread_ts : undefined,
                replies: message.reply_count ?? 0,
            })),
        };
    },

    /// One thread, when a channel message turned out to be the start of the
    /// conversation rather than the whole of it.
    read_thread: async (connection, params) => {
        const channel = requireString(params, "channel");
        const thread = requireString(params, "thread");
        const payload = await call(connection, "conversations.replies", {}, {
            method: "GET",
            query: { channel, ts: thread, limit: "100" },
        });
        const messages = (payload.messages as {
            user?: string;
            bot_id?: string;
            text?: string;
            ts?: string;
        }[] | undefined) ?? [];

        const said = messages.filter((message) => !message.bot_id && (message.text ?? "").trim());
        const names = await displayNames(connection, said.map((message) => message.user));

        return {
            messages: said.map((message) => ({
                author: names[message.user ?? ""] ?? message.user ?? "someone",
                text: message.text ?? "",
                at: slackTimestamp(message.ts),
            })),
        };
    },

    /// The workspace's members, for matching a person to their Slack account by
    /// address. Same shape `linear.list_users` answers with, so the executor's
    /// identity import does not branch per provider.
    list_users: async (connection) => {
        const members = await workspaceMembers(connection);

        return {
            users: members
                .filter((member) => !member.deleted && !member.is_bot && member.profile?.email)
                .map((member) => ({
                    id: member.id,
                    name: member.profile?.real_name ?? member.real_name,
                    email: member.profile?.email,
                })),
        };
    },

    /// Creates a channel and returns what a person needs to find it.
    ///
    /// Public by default. A private channel is invisible to everybody not
    /// invited, including the people who were in the meeting and are named a
    /// week later — the quieter default is the one that loses information.
    create_channel: async (connection, params) => {
        const name = channelName(requireString(params, "channel_name"));
        const isPrivate = params.is_private === true || params.is_private === "true";

        const payload = await call(connection, "conversations.create", {
            name,
            is_private: isPrivate,
        });
        const channel = payload.channel as { id?: string; name?: string } | undefined;
        if (!channel?.id) {
            throw new ActionError("provider_error", "Slack did not create the channel.", 502);
        }

        // Invitations ride along when the proposal carried them, so "create a
        // channel and add the three of us" is one approval rather than two.
        const invites = memberIDs(params, "invite_member_ids");
        if (invites.length > 0) {
            await call(connection, "conversations.invite", {
                channel: channel.id,
                users: invites.join(","),
            });
        }

        const team = typeof params.team_domain === "string" ? params.team_domain : null;
        return {
            // `key`, `title`, `url` — the same three words every provider action
            // answers with, so the executor stores the result without knowing
            // which product it asked.
            key: `#${channel.name ?? name}`,
            title: channel.name ?? name,
            url: team
                ? `https://${team}.slack.com/archives/${channel.id}`
                : `https://slack.com/app_redirect?channel=${channel.id}`,
            invited: invites.length,
        };
    },

    invite_users: async (connection, params) => {
        const channel = requireString(params, "channel_id");
        const users = memberIDs(params, "invite_member_ids");
        if (users.length === 0) {
            throw new ActionError("invalid_params", "`invite_member_ids` is required.");
        }

        await call(connection, "conversations.invite", { channel, users: users.join(",") });
        return { key: channel, invited: users.length };
    },
};
