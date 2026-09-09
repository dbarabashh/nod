# Integration app manifests

Configuration for the third-party apps people authorize, kept here rather than
clicked into a provider's dashboard.

The reason is not tidiness. **A scope list is a privacy claim.** `privacy.md`
says Nod reads only the channels it was added to and never reads direct
messages, and the consent screen a person actually reads is generated from these
scopes. Held in a dashboard, the two drift with nothing in the repository to
show it happened — and the consent screen is the version a buyer's security
review believes.

## Slack — `slack-app-manifest.json`

The app is **Nod**, `A0BR09EJ62H`, in the Nod workspace. Pipedream Connect runs
the OAuth dance and holds the credentials, which is why the redirect url is
theirs: Slack refuses to return anybody to an address that isn't listed in the
manifest.

**A custom OAuth client has its own callback, keyed by the client id** —
`https://api.pipedream.com/connect/oauth/<oauthAppId>/callback`, not the shared
one. Both are listed: the shared address is what Pipedream's own client returns
to, and dropping it would break every connection made before we brought our own.
Creating a second custom client means adding its callback here too, or the
consent screen ends at "redirect_uri did not match any configured URIs".

**This app is not the one people currently authorize.** Connect defaults to
Pipedream's own OAuth client for every app in its catalogue, and that is what
every live connection has used so far — `oauth_app_id` is null on all of them.
So the screen a person reads today says *"Allow the Pipedream app to access
Slack"*, and the scopes it asks for are Pipedream's, not the curated set below.
The manifest is the ceiling we would ask for; right now nothing asks it.

The manifest is the exact shape Slack accepts — no comments, no extra keys, or
`apps.manifest.update` rejects the whole file with `invalid_manifest`.

**Applying a change.** Either edit the scopes under *OAuth & Permissions* in
the Slack app and mirror them into this file, or push this file with the API.
The API needs an app configuration token from
[api.slack.com/apps](https://api.slack.com/apps) → *Your App Configuration
Tokens* → Generate — a 12-hour key for `apps.manifest.*` and nothing else. It is
not stored and not reused, so every change needs a fresh one; that is the only
reason it keeps coming up.

```sh
curl -s https://slack.com/api/apps.manifest.update \
  -d token="$SLACK_CONFIG_TOKEN" -d app_id=A0BR09EJ62H \
  --data-urlencode manifest@supabase/integrations/slack-app-manifest.json
```

Creating one from scratch is `apps.manifest.create` with the same file and no
`app_id`; it answers with the `client_id` and `client_secret` that a **custom
OAuth client** in Connect would need.

**When to make Nod the app on the consent screen.** A custom client is what puts
our name and our scopes there instead of Pipedream's, and a scope list that
nobody is asked for is a privacy claim we cannot evidence — which is the whole
argument at the top of this file. Against that: Connect does not support custom
clients in *triggers* for Slack, Discord, Dropbox or Zoom (actions and code
steps are fine), and it is per-app work rather than something the catalogue
gives us. Worth doing for the products we adapt and name in `privacy.md`; not
worth doing for three thousand.

Create one in the Connect UI, on the app itself: **Connect → Apps → Slack →
Custom OAuth client**, where the Slack app's `client_id` and `client_secret` go.
There is no CLI for this — `pd oauth-client create` is a different thing
entirely: it mints credentials for calling *Pipedream's own* API, which is what
`PIPEDREAM_CLIENT_ID` / `PIPEDREAM_CLIENT_SECRET` hold, and it takes only a
name. Changing scopes afterwards makes everyone reconnect.

**What the scopes are for.**

| Scopes | Why |
|---|---|
| **bot** `channels:read`, `channels:history`, `channels:join`, `groups:read`, `groups:history` | Reading channels — `list_channels`, `read_channel`, `read_thread` in `functions/_shared/integrations/slack.ts`. `channels:join` is what lets Nod read a public channel nobody invited it to: Slack gives a bot no other way in, so the choice is between joining — which the channel sees — and not answering |
| **user** `channels:read`, `channels:history`, `groups:read`, `groups:history` | The same reads, as the person who connected. The bot scopes above reach a private channel only where somebody invited the bot, which is not where the user's own work happens — "what did we decide in the private channel I'm in" was unanswerable with bot scopes alone, whatever the question |
| **user** `search:read` | `search_messages`. A question naming a person or a day and no channel — "what did Vlad send today" — has nowhere to start otherwise, and walking every channel to answer it spends the whole latency budget. Slack offers this endpoint to user tokens only |
| `channels:manage`, `channels:write.invites`, `groups:write`, `groups:write.invites` | Opening a channel for what a meeting decided, and adding the people in it |
| `users:read`, `users:read.email` | Matching a colleague to their Slack account by address, for the organization directory |

Deliberately absent: `im:read`, `im:history`, `mpim:read`, `mpim:history`
(direct messages), `files:*`, `users:write`, `team.billing:read`, and
`incoming-webhook` — the last one is what made Slack demand a channel during
installation for a webhook Nod never uses.

**The user scopes need a custom OAuth client to be asked for at all.** Connect
runs Pipedream's own client by default, so the consent screen asks Pipedream's
scopes and this table is a ceiling nobody reaches — `search_messages` fails with
`missing_scope` on a connection that is otherwise healthy. Updating the manifest
does not change that on its own; the custom client above is what makes these the
scopes a person is actually asked for. Whether Connect's proxy then presents the
**user** token rather than the bot one is unverified: if it does not,
`assistant.search.context` answers `not_allowed_token_type` even with the scope
granted.

**`search:read` is the one scope wider than what it is used for.** Slack does
not divide search by conversation type, so a token that can search channels can
search direct messages too. `privacy.md` § 3.16 promises those are never read,
and with this scope granted that promise can no longer rest on the scope list —
it rests on `fromAChannel()` and `isDirect()` in `slack.ts`, which drop every
direct and group match, and treat a conversation they cannot positively identify
as a channel as direct. Anything that weakens those functions breaks a published
claim.

**Scopes are declared twice.** Here, which is the ceiling of what the app may
ever ask for, and in whichever OAuth client actually runs the flow, which is
what it asks for this time.
That is OAuth's shape, not duplication of ours — but they have to agree, or the
authorization succeeds and the first API call fails with `missing_scope`.

## Write scopes the 2026-09-01 tool widening needs

The chat gained writes against previously read-only providers, and each needs
its OAuth grant to actually allow them. **Grants do not widen retroactively**:
a connection made under read scopes answers a write with a 403 until the person
reconnects, whichever consent screen the catalogue shows. Verify against the
Connect app (or our custom client, where one exists) before calling any of
these live, and expect a reconnect wave when scopes change:

| Provider | Needs | For |
|---|---|---|
| Gmail | `gmail.compose` (or `gmail.modify`) alongside the read scope | `create_draft` |
| Google Drive | a content-read scope (`drive.readonly` covers it; metadata-only does not) | `read_file` |
| Google Calendar | `calendar.events` (read-write, already required by `create_event`) | `update_event`, `delete_event` |
| GitHub | `repo` (issues write rides it) | `create_issue`, `comment_issue`, `update_issue` |
| Notion | capabilities: insert content | `create_page`, `append_page` |
| HubSpot | `crm.objects.notes.write` (plus the object read scopes) | `create_note` |

Pipedream's own OAuth clients generally ask broadly, which is why today's
read-only behavior was a property of our adapters rather than of the grants —
the table above is what a *curated* client must not fall below.

## Google Tasks — scope and reach

Pipedream's `google_tasks` app asks for `https://www.googleapis.com/auth/tasks`,
the API's one read-write scope; there is no narrower grant that still lets Nod
file a task. A custom OAuth client, if we bring one, is named to the functions
as `PIPEDREAM_OAUTH_APP_GOOGLE_TASKS`. The adapter
(`functions/_shared/integrations/googleTasks.ts`) reads and writes **the
default list only** (`lists/@default`) — the one every account has and the one
the Today card means by "make this a task". Other lists are never listed, read
or written.

| Action | Does | Reads |
|---|---|---|
| `create_task` | Inserts a task with `title`, optional `notes`, optional `due` (a day: Google keeps the date and drops the time) | — |
| `search_tasks` | Keeps the tasks whose title or notes carry the words asked for, open and completed alike; cleared tasks are not read | one page of the default list |
| `read_tasks` | Whether tasks Nod filed have since been completed, for the checkbox reconciliation; a task Google no longer has is left out | each task by id |
| `update_task` | Retitles, re-dates (or clears the date), completes or reopens a task, replaces its notes or adds a note below them | the task, when a note is appended |

Not a directory source: the Tasks API knows no members, so there is no
`list_users` and no "Import members" for it.

## Google Calendar — when it is read, and what it costs

Every read of a connected calendar is one request through the Connect proxy,
and Connect meters requests. Until 2026-09-02 `calendar-sync` swept every
connected calendar every ten minutes, day and night (`20260815124210`): 4,320
requests per calendar a month before pagination, for a calendar nobody was
looking at most of that time. Linear NOD-136.

**The app asks, and says why.** `RemoteCalendar.sync(reason)` calls
`calendar-sync` with the user's JWT and one of four reasons. The server holds a
floor per reason (`functions/_shared/integrations/calendarRefresh.ts`) and
`claim_calendar_read` takes the read atomically — the floor has passed and the
month's cap is not spent — or answers "not yet" without touching Google. The
client mirrors the floors (`CalendarSyncReason.floor`) so it never sends an ask
the server would refuse; `NodTests/CalendarSyncScheduleTests` pins the mirror.

| Reason | When the app sends it | Floor |
|---|---|---|
| `open` | launch, sign-in, the app coming forward, Today shown | 15 min |
| `idle` | the watcher's tick, once nothing has been read for an hour | 60 min |
| `approaching` | the watcher's tick, while an entry starts within 30 min | 5 min |
| `call` | a recording starts, before the invitation is matched | 2 min |

`synced_at` on `calendar_sync_state` is stamped on every attempt, succeeded or
not, so a provider that keeps refusing is retried no faster than one that
answers. `MONTHLY_READ_CAP` (3,000 proxied requests per calendar per UTC
month — pages count, since pages are what the proxy meters) is the budget above
which the claim answers `capped`; the app then holds every timed ask until the
month turns. A `call` read is exempt on both sides: one per recording, and the
read that names the meeting. A client that hits the budget is misbehaving, and
nobody else is affected. The budget is read from the tally below, which is
best-effort: a tally that cannot be written leaves the budget unspent, never
the calendar unread.

**The sweep is a safety net.** `sync-calendars` runs once a day (`45 4 * * *`)
and reads only accounts the app has not asked about for twenty hours. An
account whose Nod is running costs the sweep nothing; a connected calendar whose
Nod has been closed for a week costs one read a day, so Today is right the
moment it reopens rather than after its first ask.

**Freshness.** With Nod running, a change to an entry within the next half hour
lands within five minutes; a new invitation for later in the day within an
hour, or the moment the app comes forward; a recording matches against a copy
no older than two minutes. With Nod closed nothing needs the calendar, and the
daily sweep keeps the copy from going stale beyond a day.

**Cost model** — one page per read (≤250 entries in the nine-day window), no
retries (a failed read waits its floor), Nod running nine hours on twenty-two
working days, three meetings a day:

| Reads per calendar per month | |
|---|---|
| `open` — about five activations a day past the floor | 110 |
| `idle` — the hours nothing else read | 130 |
| `approaching` — up to seven per meeting (35 minutes over a 5-minute floor) | 460 |
| `call` — one per meeting | 66 |
| sweep — zero while the app is used; 30 for an account that never opens it | 0–30 |
| **Total** | **≈ 800** (was 4,320) |

Six meetings a day, back to back, is about 1,200. The ceiling through the
floors alone is twelve reads an hour for a calendar with a meeting always
within the half hour — 2,400 a month over the working hours modelled here, and
more for a Mac left running around the clock with such a calendar, which is
the one honest case the cap would also stop.

| Connected calendars | 1 | 10 | 100 | 1,000 | 10,000 |
|---|---|---|---|---|---|
| Reads a month (modelled) | 800 | 8,000 | 80,000 | 800,000 | 8 M |
| Reads a month (old sweep) | 4,320 | 43,200 | 432,000 | 4.32 M | 43.2 M |

Pipedream does not publish a per-request price for the proxy: credits are
metered as compute (one credit per 30 s at 256 MB), a proxy request is well
under one, and the plans bundle credits by the day — the Advanced plan's
roughly 10,000 a day — about 300,000 a month — covers a few hundred modelled
calendars at the current pricing, after which the Business plan's terms apply. Those figures come from
Pipedream's own pricing docs and third-party summaries as of 2026-09-02;
confirm them on `pipedream.com/pricing` before setting a plan price on them.

**What is measured.** Every proxied request, calendar or not, adds one to
`integration_proxy_requests` (person, provider, purpose, day) through
`count_proxy_request`; `purpose` is `action` for a tool call and
`calendar-<reason>` / `calendar-sweep` for the reads above. The count is handed
to the edge runtime's `waitUntil` so it never sits on a response's critical
path, and it is bounded to two seconds. Per-user monthly spend per capability
is one query on that table; it is kept thirteen months. The chat's own calendar
reads (`list_events`, free/busy) are counted as `action` and are outside the
cap: they happen once per question somebody asked.

**What would take the cost to near zero** is push: Google's `events.watch`
delivers a notification to a URL of ours whenever the calendar changes, and a
read then happens only on a change. That needs a channel per calendar renewed
weekly (one proxied `watch` a week), a receiving function, and — through
Connect — a custom OAuth client for Google Calendar, which is the same
prerequisite as putting Nod's name on the consent screen. Not built; the floors
above are what stand until it is.

## Connect environments — and what production needs

Every Connect call carries `x-pd-environment`, set from `PIPEDREAM_ENVIRONMENT`
per Supabase branch. Sandbox is `development`; production is `production`, and
that is not a label.

Both branches address the same Connect project, `proj_zNsB5P7` — one project
holds both environments, so the switch is the variable and nothing else. They
also share one `PIPEDREAM_CLIENT_ID` / `PIPEDREAM_CLIENT_SECRET` pair, which is
a credential for Pipedream's own API rather than any provider's, and which means
a sandbox compromise reaches production. A separate client for production
(`pd oauth-client create`) is the fix, and it is not done.

`development` is capped at **10 external users**, and everyone connecting through
it must be signed in to pipedream.com. It is for our own testing, not for
customers — a real user who is not a Pipedream account holder simply cannot
finish the flow. Production access is enabled on Pipedream's pricing page, not
by flipping the variable.

**Sandbox ran `production` until 2026-09-09**, against this file's own
instruction, so every test connection was billing as a production external user.
Moving it to `development` retired the sixteen connections that were live —
`state` and `revoked_at` both, which is what the retirement script now sets.

**Grants do not cross.** Connected accounts and credentials in one environment
are invisible to the other, so every connection made while testing has to be
made again in production. That is a line in the release plan, not a surprise to
find afterwards: `integration_connections` rows written against a development
account address nothing once the environment changes.

**Setting the secret is the whole switch — no redeploy.** Supabase states that
secrets are "available immediately in your functions", and a `functions deploy`
of unchanged source is deduplicated into a no-op anyway, so redeploying proves
nothing and changes nothing. (This paragraph used to claim the opposite, on the
strength of the module-load read in `pipedream.ts`; the read is real, but new
isolates already boot with the current secret.)

What the switch *does* need is retiring the connections it orphans. Every row in
`integration_connections` points at an account in the old environment, so the
client keeps drawing "Connected" over a grant that answers
`Auth provision owner mismatch`. Run
`scripts/sql/retire-connections-after-environment-switch.sql` against the branch,
then everyone reconnects. Revoking fires `purge_provider_data`, which is correct
— the grant is gone and its data cannot be refreshed.

## Who may act — the organization's half of the answer

A connection is one permission and `org_integration_policies` is the other, and
every path that reaches a provider has to hold both. The table, the admin pane
and `org_allows_provider` shipped in `20260816240000`, but only
`approve_proposal` and `proposal-execute` ever asked; the chat's tool calls, the
roster imports and the scheduled calendar read did not. So switching Slack off
stopped the client drawing the button and stopped nothing else.

`20260827160000` puts the check where the action is and `20260827170000` makes
it the only expression of the rule. One join, three shapes:

| | Question | Callers |
|---|---|---|
| `user_may_use_provider(user, provider)` | may this person act in it? | `resolveConnection`, `proposal-execute`, `approve_proposal`, `agent_approve_proposal` |
| `users_barred_from_provider(users[], provider)` | which of these may not? | `calendar-sync`, `integration-reconcile` |
| `my_blocked_providers()` | what is off for me? | the desktop client |

The first two are `service_role` only: the argument is a user id, and a grant to
`authenticated` would answer questions about other people's employers.
`my_blocked_providers` takes no argument, so it can only answer about its
caller — which is why it is the one the client gets, and why the client renders
a server answer instead of deriving a parallel rule from the policy rows.

**`resolveConnection` is the gate, not the five doors.** Every path that reaches
a provider needs a `Connection`, so gating its construction is what makes the
policy structurally true rather than something each caller has to remember. The
two paths that build a `Connection` by hand — `calendar-sync` and the roster
import in `integration-reconcile` — ask `barredUsers` in the batch shape their
fan-out needs. `proposal-execute` asks a second time before it claims the
proposal, so a refusal leaves the proposal `approved` and retryable rather than
`failed`.

Not at `proxy()`, though every provider call passes through it: several adapters
fire two proxy calls per action and the calendar paginates up to ten pages per
account, so the check would need a cache — and a cached policy contradicts the
reason for checking at all. It would also break connecting on purpose-built
identity reads, and connecting a forbidden product stays allowed.

**Any organization, not the current one.** Somebody can belong to two, and a
rule that let a permissive membership relax a forbidding one would be a way
around the control. A forbidding organization forbids.

**Absence still means allowed.** No row is not a denial, and an account in no
organization is barred from nothing.

**A check that cannot be run refuses**, as `policy_unavailable` rather than as
a policy — denying with "your organization does not allow this" would state a
company's position we failed to read. It costs nothing in practice: the same
database answers `resolveConnection` a line later. The sweep is the exception
and skips everyone on a failed read, because a missed sync round is recoverable
and reading a calendar a company forbade is not.

**Deploy order: the migration, then the functions.** They fail closed, so
functions that land on an instance without `user_may_use_provider` refuse every
integration action until it does. Rollback is the reverse: redeploy the previous
functions, leave the functions in the database — nothing else reads them.

**`org_allows_provider` is gone.** `20260827170000` moved `approve_proposal`
onto the shared rule and revoked its `authenticated` grant — it took an
arbitrary organization id, so any signed-in account could enumerate any
organization's policy. `agent_approve_proposal` had since picked it up again,
asking one organization and skipping the check when the proposal carried none;
`20260902114020` moves that last caller onto `user_may_use_provider` and drops
the function. `supabase/tests/integration_policy_contract.sql` fails if it
comes back.

**Retiring is a schema change, not a config one.** All three functions are
additive; dropping any of them means finding every caller above first.
