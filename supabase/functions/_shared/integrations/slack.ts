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
    options: {
        method?: "GET" | "POST";
        query?: Record<string, string | undefined>;
    } = {},
): Promise<Record<string, unknown>> {
    const payload = await proxy(connection, method, body, options) as
        | { ok?: boolean; error?: string }
        | null;

    if (!payload?.ok) {
        const detail = payload?.error ?? "unknown_error";
        throw new ActionError(
            SLACK_ERRORS[detail] ?? "provider_error",
            messageFor(detail),
            502,
            detail,
        );
    }
    return payload as Record<string, unknown>;
}

/// Slack's error strings, mapped to codes a caller can act on. Anything absent
/// stays `provider_error`, which the review card renders as a plain failure.
export const SLACK_ERRORS: Record<string, string> = {
    name_taken: "name_taken",
    invalid_name_specials: "invalid_params",
    invalid_name_maxlength: "invalid_params",
    // Not `reauthorize`, however much it looks like an auth problem. The
    // connection is alive — every other call on it works — and the app simply
    // never asked for this permission. Reconnecting runs the same app through
    // the same consent screen and grants the same scopes, so telling somebody
    // to reconnect sends them to do a thing that cannot work, and they come
    // back believing the integration is broken. One person disconnected Slack
    // over this message.
    missing_scope: "not_permitted",
    // Slack's word for "this endpoint needs a user token and you sent a bot
    // one". Not a scope the user can grant by reconnecting either.
    not_allowed_token_type: "not_permitted",
    not_authed: "reauthorize",
    invalid_auth: "reauthorize",
    account_inactive: "reauthorize",
    restricted_action: "not_permitted",
};

export function messageFor(error: string): string {
    switch (error) {
        case "name_taken":
            return "A Slack channel with that name already exists.";
        case "missing_scope":
            return "Nod's Slack app has no permission for this. Reconnecting won't add it — the app's scopes have to be updated.";
        case "not_authed":
        case "invalid_auth":
        case "account_inactive":
            return "Nod's Slack access needs to be reconnected in Settings → Integrations.";
        case "restricted_action":
            return "This Slack workspace does not allow that.";
        case "not_allowed_token_type":
            return "Searching Slack needs a user-level connection; this workspace is connected as an app.";
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
        throw new ActionError(
            "invalid_params",
            `"${raw}" leaves no usable Slack channel name.`,
        );
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
        throw new ActionError(
            "invalid_params",
            `At most ${MAX_INVITES} people per invitation.`,
        );
    }
    // Member ids, never names or addresses. Anything else reaching this point
    // means the executor failed to resolve somebody and the call must not go
    // ahead with a string Slack would either reject or, worse, match loosely.
    for (const id of list) {
        if (!/^[UW][A-Z0-9]{2,}$/.test(id)) {
            throw new ActionError(
                "unresolved_person",
                `"${id}" is not a Slack member id.`,
            );
        }
    }
    return list;
}

/// Everybody a call is meant to invite, as Slack member ids.
///
/// Two ways in, because there are two callers and they know different things. A
/// proposal raised from a meeting carries `people` rows, already resolved to
/// member ids by the executor. The chat and the meeting box carry addresses —
/// they have the organization directory in their prompt and no way to learn a
/// Slack id — exactly as `google-calendar.create_event` already takes addresses
/// for its guests.
///
/// Both end in member ids before anything is invited. An address that matches
/// nobody in the workspace is an error and not a silent omission: "add Anna,
/// Alex and John" that quietly adds two of them is worse than one that fails.
async function invitees(connection: Connection, params: Record<string, unknown>): Promise<string[]> {
    const ids = memberIDs(params, "invite_member_ids");
    // `invite_emails` is the older name and still arrives from the chat.
    const named = [...list(params, "invite_people"), ...list(params, "invite_emails")];
    if (named.length === 0) return ids;
    if (ids.length + named.length > MAX_INVITES) {
        throw new ActionError("invalid_params", `At most ${MAX_INVITES} people per invitation.`);
    }

    const resolved: string[] = [];
    for (const person of named) {
        const member = await memberFor(connection, person);
        if (!member.id) {
            throw new ActionError("unresolved_person", `"${person}" has no Slack account to invite.`);
        }
        resolved.push(member.id);
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
        if (
            !(error instanceof ActionError) || error.providerCode !== "not_in_channel"
        ) throw error;
        await call(connection, "conversations.join", { channel });
        return await read();
    }
}

/// One message as the model reads it, wherever it came from.
interface SlackSaid {
    user?: string;
    /// A search match carries a name where a history read carries only an id.
    username?: string;
    bot_id?: string;
    text?: string;
    ts?: string;
    thread_ts?: string;
    reply_count?: number;
}

/// Bot posts are dropped — deploy notifications are not what anybody means by
/// "what did we say" — and so is anything with no text to read.
export function worthReading(message: SlackSaid): boolean {
    return !message.bot_id && (message.text ?? "").trim().length > 0;
}

/// One thread's replies, without the parent: `conversations.replies` answers
/// with the message the thread hangs off, and it is already in the channel read
/// that pointed here.
async function replies(
    connection: Connection,
    channel: string,
    thread: string,
    limit: number,
): Promise<SlackSaid[]> {
    const payload = await call(connection, "conversations.replies", {}, {
        method: "GET",
        query: { channel, ts: thread, limit: String(limit) },
    });
    const messages = (payload.messages as SlackSaid[] | undefined) ?? [];
    return messages.filter((message) => message.ts !== thread).filter(
        worthReading,
    );
}

/// How much of a conversation's replies ride along with the channel read.
///
/// They ride along rather than waiting to be asked for, because a caller that
/// has to ask cannot: the thread's id only exists in the result it would be
/// asking about, and the surfaces reading this get two calls in total. A
/// channel whose answer is six replies deep was unanswerable until this.
///
/// Bounded because a busy channel is fifty messages of which twenty have
/// replies, and reading all of them is a minute of API calls for two sentences.
/// Newest first, since a question asked now is almost always about the newest.
export const THREADS_PER_READ = 3;
export const REPLIES_PER_THREAD = 20;

/// One said thing as the model reads it.
///
/// The one projection: three copies of these three fields is how the workspace
/// search came to spell the author fallback differently from the two handlers
/// beside it.
export function readable(
    names: Record<string, string>,
    message: SlackSaid,
): { author: string; text: string; at: string } {
    return {
        author: names[message.user ?? ""] ?? message.username ?? message.user ?? "someone",
        text: message.text ?? "",
        at: slackTimestamp(message.ts),
    };
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
    /// The `@handle`, which is what search's `from:` modifier matches on —
    /// distinct from every other name a member carries.
    name?: string;
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

async function workspaceMembers(
    connection: Connection,
): Promise<SlackMember[]> {
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
        names[member.id] = member.profile?.display_name ||
            member.profile?.real_name || member.real_name || member.id;
    }
    return names;
}

/// A person named the way somebody says it out loud, matched to their Slack
/// handle.
///
/// Search's `from:` matches on the handle, and nobody asking a question knows
/// it — they say "Vlad", or they know the address. Both are resolved here
/// against the roster we already fetch, so the caller never has to.
///
/// An unmatched name is an error rather than a dropped filter: a search for
/// what Vlad said that quietly returns what everybody said is worse than one
/// that says it could not find Vlad.
async function handleFor(connection: Connection, person: string): Promise<string> {
    const member = await memberFor(connection, person);
    if (!member.name) {
        throw new ActionError("unresolved_person", `"${person}" has no Slack handle to search by.`);
    }
    return member.name;
}

/// Cyrillic written the way a Latin workspace writes it.
///
/// The request is in the language the person speaks and the workspace is in
/// English: "запроси Влада" against a profile that says "Vlad Kampov" matched
/// nothing, so the invitation failed on a colleague who was right there. Both
/// sides are folded through this before they are compared, so it does not
/// matter which alphabet either was written in.
///
/// Ukrainian's romanisation, which differs from Russian's where they disagree
/// (`г` is `h`, `и` is `y`); the few Russian-only letters are mapped to what
/// they sound like rather than left to fail.
const ROMAN: Record<string, string> = {
    а: "a",
    б: "b",
    в: "v",
    г: "h",
    ґ: "g",
    д: "d",
    е: "e",
    є: "ie",
    ж: "zh",
    з: "z",
    и: "y",
    і: "i",
    ї: "i",
    й: "i",
    к: "k",
    л: "l",
    м: "m",
    н: "n",
    о: "o",
    п: "p",
    р: "r",
    с: "s",
    т: "t",
    у: "u",
    ф: "f",
    х: "kh",
    ц: "ts",
    ч: "ch",
    ш: "sh",
    щ: "shch",
    ь: "",
    ю: "iu",
    я: "ia",
    ы: "y",
    э: "e",
    ё: "e",
    ъ: "",
};

export function latinise(text: string): string {
    return [...text.toLowerCase()].map((letter) => ROMAN[letter] ?? letter).join("");
}

/// The workspace member somebody means, however they said it.
///
/// One resolver for both callers. Search matches on a handle and an invitation
/// takes a member id, but neither is a thing a person says: they say "Vlad", or
/// they know the address. Resolving that here is what lets a tool schema ask
/// for what the asker actually has.
async function memberFor(connection: Connection, person: string): Promise<SlackMember> {
    const wanted = person.trim().toLowerCase().replace(/^@/, "");
    if (!wanted) throw new ActionError("invalid_params", "`from` was empty.");

    const members = await workspaceMembers(connection);
    const alive = members.filter((member) => !member.deleted && !member.is_bot);
    const roman = latinise(wanted);
    const names = (member: SlackMember) =>
        [member.name, member.profile?.display_name, member.profile?.real_name, member.real_name]
            .filter((name): name is string => Boolean(name))
            .map((name) => name.toLowerCase());

    const candidates = [
        (member: SlackMember) => member.profile?.email?.toLowerCase() === wanted,
        (member: SlackMember) => names(member).includes(wanted),
        // The same names read in one alphabet, so "Влад" reaches "Vlad" and
        // "Vlad" reaches "Влад".
        (member: SlackMember) => names(member).map(latinise).includes(roman),
        // Last, and only on a first name: "Vlad" should find "Vlad Petrenko",
        // and it is worth an ambiguous match here because the alternative is
        // telling the user their colleague does not exist.
        (member: SlackMember) => names(member).map((name) => latinise(name).split(" ")[0]).includes(roman),
    ];

    for (const matches of candidates) {
        const found = alive.find(matches);
        if (found) return found;
    }
    throw new ActionError(
        "unresolved_person",
        `Nobody in this Slack workspace matches "${person}".`,
    );
}

/// A date as Slack's search modifiers take it, or nothing.
function searchDate(
    params: Record<string, unknown>,
    key: string,
): string | null {
    const raw = params?.[key];
    if (typeof raw !== "string" || !raw.trim()) return null;
    const day = raw.trim().slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
        throw new ActionError(
            "invalid_params",
            `\`${key}\` must be a date like 2026-08-26.`,
        );
    }
    return day;
}

/// Whether a search hit came out of a direct or group message.
///
/// Both the flags Slack sets and the id prefix it uses, because either alone
/// has failed somebody: a hit with no channel object at all must not be assumed
/// to be a channel, and `D…` is what a direct message id has always looked
/// like. Anything unrecognised counts as direct — the safe answer when the
/// question is whether we are allowed to read something.
export function isDirect(
    channel: { id?: string; is_im?: boolean; is_mpim?: boolean } | undefined,
): boolean {
    if (!channel) return true;
    if (channel.is_im === true || channel.is_mpim === true) return true;
    const id = channel.id ?? "";
    // No id and no flags identifies nothing. Dropping a channel hit loses an
    // answer; keeping a direct one breaks a published promise, so it fails
    // closed.
    if (!id) return true;
    return id.startsWith("D");
}

/// The structured filters, assembled into the one string Slack's search takes.
///
/// Structured on the way in and a query string only here, because a model fills
/// named parameters reliably and invents a query DSL unreliably — and a
/// malformed modifier does not fail, it silently searches for its own text.
/// One result from `assistant.search.context`. Nothing like `search.messages`
/// answered with: the author's name and the channel's arrive resolved, so the
/// roster lookup the old shape needed to turn `U0…` into a person is gone.
export interface SearchHit {
    author_name?: string;
    author_user_id?: string;
    channel_id?: string;
    channel_name?: string;
    message_ts?: string;
    content?: string;
    is_author_bot?: boolean;
    permalink?: string;
}

/// Whether a hit is worth putting in front of the model — the same question
/// `worthReading` answers for a channel read, asked of the shape search
/// returns. `include_bots: false` already asks Slack for this; a filter that
/// exists only in the request is one API default away from silently lapsing.
export function worthQuoting(hit: SearchHit): boolean {
    return hit.is_author_bot !== true && (hit.content ?? "").trim().length > 0;
}

/// Whether a hit came from a channel rather than a direct or group message.
///
/// `privacy.md` § 3.16 promises those are never read, and `channel_types` asks
/// Slack for channels only — but that is a request, and this is the
/// enforcement. A hit with no channel name is treated as direct: search names
/// every channel it returns, so an unnamed conversation is one, and losing a
/// result costs an answer where keeping a direct one breaks a promise.
export function fromAChannel(hit: SearchHit): boolean {
    if ((hit.channel_name ?? "").trim() === "") return false;
    return !isDirect({ id: hit.channel_id });
}

/// The parts of a search, as the Real-time Search API wants them: the words to
/// look for, and the filters that narrow where to look.
///
/// Separated rather than joined, because `assistant.search.context` takes them
/// as two arguments. `query` is matched semantically; putting `from:@vlad` in
/// there would have the search look for the *phrase*.
export interface SearchTerms {
    text: string;
    modifiers: string;
}

export function searchTerms(
    params: Record<string, unknown>,
    handle: string | null,
): SearchTerms {
    const text = typeof params?.text === "string" ? params.text.trim() : "";
    const channel = typeof params?.in === "string" ? params.in.trim().replace(/^#/, "") : "";

    const modifiers: string[] = [];
    if (handle) modifiers.push(`from:@${handle}`);
    if (channel) modifiers.push(`in:#${channel}`);
    for (const key of ["on", "after", "before"] as const) {
        const day = searchDate(params, key);
        if (day) modifiers.push(`${key}:${day}`);
    }

    if (!text && modifiers.length === 0) {
        throw new ActionError(
            "invalid_params",
            "Give at least one of `text`, `from`, `in`, `on`.",
        );
    }
    return { text, modifiers: modifiers.join(" ") };
}

/// What the search came down to, for the model to read back. Both parts as one
/// line, which is also how a person would have typed it into Slack.
export function searchQuery(terms: SearchTerms): string {
    return [terms.text, terms.modifiers].filter(Boolean).join(" ");
}

// `assistant.search.context` caps a page at 20 and silently returns fewer
// rather than refusing, so asking for more would quietly look like a thin
// workspace instead of a truncated page.
const SEARCH_LIMIT = 20;

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
        // The roster needs nothing from the messages. Fetched alongside them
        // rather than after, so a cold cache — every fresh isolate has one —
        // does not add its own round trip to every channel read.
        const [payload] = await Promise.all([
            history(connection, channel, limit),
            workspaceMembers(connection).catch(() => [] as SlackMember[]),
        ]);
        const messages = (payload.messages as
            | (SlackSaid & { type?: string; subtype?: string })[]
            | undefined) ?? [];

        const said = messages.filter((message) => message.type === "message" && !message.subtype).filter(worthReading);

        // The newest conversations, read in one go rather than one after
        // another: they have nothing to say to each other, and the surfaces
        // waiting on this are watching a spinner.
        const discussed = said.filter((message) => message.thread_ts && (message.reply_count ?? 0) > 0)
            .slice(0, THREADS_PER_READ);
        const threads = await Promise.all(
            discussed.map(async (message) => ({
                ts: message.ts,
                // A thread that cannot be read is not a channel read that
                // failed. The messages above it are still the answer.
                replies: await replies(
                    connection,
                    channel,
                    message.thread_ts ?? "",
                    REPLIES_PER_THREAD,
                )
                    .catch(() => [] as SlackSaid[]),
            })),
        );
        const byParent = new Map(
            threads.map((thread) => [thread.ts, thread.replies]),
        );

        const names = await displayNames(
            connection,
            [...said, ...threads.flatMap((thread) => thread.replies)].map((message) => message.user),
        );
        return {
            messages: said.map((message) => {
                const replied = byParent.get(message.ts) ?? [];
                return {
                    ...readable(names, message),
                    thread: message.thread_ts && message.reply_count ? message.thread_ts : undefined,
                    replies: message.reply_count ?? 0,
                    // Absent rather than empty when there is nothing: an empty
                    // array reads as "the thread was read and was empty".
                    thread_messages: replied.length > 0 ? replied.map((reply) => readable(names, reply)) : undefined,
                };
            }),
        };
    },

    /// One thread, when a channel message turned out to be the start of the
    /// conversation rather than the whole of it.
    read_thread: async (connection, params) => {
        const channel = requireString(params, "channel");
        const thread = requireString(params, "thread");
        const said = await replies(connection, channel, thread, 100);
        const names = await displayNames(
            connection,
            said.map((message) => message.user),
        );

        return { messages: said.map((message) => readable(names, message)) };
    },

    /// What was said anywhere in the workspace, by whoever, on whatever day.
    ///
    /// One call rather than a walk through channels: "did Vlad send anything
    /// today" has no channel in it, and listing every conversation to read each
    /// one would spend a question's worth of latency to answer half of it.
    ///
    /// `assistant.search.context`, not `search.messages`. The older method is
    /// the one Slack now calls legacy, and it takes only the undivided
    /// `search:read` — a scope Slack has split up and which the broker's client
    /// no longer obtains, so every call came back `missing_scope` naming a
    /// permission nobody can grant any more. This method is what the granular
    /// `search:read.public` / `search:read.private` were made for, and the
    /// account already holds them.
    ///
    /// `channel_types` is the first line on direct messages, which `privacy.md`
    /// § 3.16 promises are never read: `im` and `mpim` are simply not asked
    /// for. The filter below is the second, because an argument is a request
    /// and a promise kept only by asking nicely is not kept at all.
    search_messages: async (connection, params) => {
        // Validated before the roster is touched: resolving a name downloads
        // up to 500 members, and a call with no filters at all — which is what
        // an under-constrained model produces — is rejected either way.
        searchTerms(params, null);
        const person = typeof params?.from === "string" ? params.from.trim() : "";
        const terms = searchTerms(
            params,
            person ? await handleFor(connection, person) : null,
        );

        const payload = await call(connection, "assistant.search.context", {
            query: terms.text,
            modifiers: terms.modifiers,
            channel_types: ["public_channel", "private_channel"],
            // The same messages `worthReading` drops from a channel read. Asked
            // of Slack as well as filtered here, so a page of results is not
            // spent on posts that will be thrown away.
            include_bots: false,
            sort: "timestamp",
            sort_dir: "desc",
            limit: SEARCH_LIMIT,
        });

        const found = ((payload.results as { messages?: unknown[] } | undefined)?.messages ??
            []) as SearchHit[];

        return {
            query: searchQuery(terms),
            messages: found
                .filter(worthQuoting)
                .filter(fromAChannel)
                .map((hit) => ({
                    author: hit.author_name ?? hit.author_user_id ?? "someone",
                    text: hit.content ?? "",
                    at: slackTimestamp(hit.message_ts),
                    channel: hit.channel_name ?? hit.channel_id ?? "",
                    url: hit.permalink ?? "",
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
        const isPrivate = params.is_private === true ||
            params.is_private === "true";

        const payload = await call(connection, "conversations.create", {
            name,
            is_private: isPrivate,
        });
        const channel = payload.channel as
            | { id?: string; name?: string }
            | undefined;
        if (!channel?.id) {
            throw new ActionError(
                "provider_error",
                "Slack did not create the channel.",
                502,
            );
        }

        // Invitations ride along when the proposal carried them, so "create a
        // channel and add the three of us" is one approval rather than two.
        const invites = await invitees(connection, params);
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

    /// Adds people to a channel that already exists.
    ///
    /// Takes addresses as well as member ids, for the reason `create_channel`
    /// does: whoever asks knows an email, and a Slack id is not something a
    /// person says out loud.
    invite_users: async (connection, params) => {
        const channel = requireString(params, "channel_id");
        const users = await invitees(connection, params);
        if (users.length === 0) {
            throw new ActionError("invalid_params", "Give at least one person to invite.");
        }

        await call(connection, "conversations.invite", {
            channel,
            users: users.join(","),
        });
        return { key: channel, invited: users.length };
    },

    // The only action here that puts words in front of other people, which is
    // why it is `mutating` on the client and never runs without the card.
    //
    // A person or a channel, not both: "post this in #pricing" and "tell Vlad"
    // are the two ways anyone asks, and a call carrying both is a model that
    // has not decided. Addressing a person posts a direct message, which is a
    // different thing from *reading* one — `privacy.md` § 3.16 promises Nod
    // never reads DMs, and writing one the user dictated does not touch that.
    post_message: async (connection, params) => {
        const text = requireString(params, "text");
        const channel = typeof params?.channel_id === "string" ? params.channel_id.trim() : "";
        const person = typeof params?.to === "string" ? params.to.trim() : "";
        if (channel && person) {
            throw new ActionError("invalid_params", "Give either `channel_id` or `to`, not both.");
        }

        let target = channel;
        if (!target) {
            if (!person) {
                throw new ActionError("invalid_params", "Give a `channel_id` to post in, or `to` for a person.");
            }
            target = (await memberFor(connection, person)).id;
        }

        const payload = await call(connection, "chat.postMessage", { channel: target, text });
        return { key: target, ts: payload.ts ?? null };
    },
};
