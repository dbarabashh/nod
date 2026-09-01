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
`search.messages` answers `not_allowed_token_type` even with the scope granted.

**`search:read` is the one scope wider than what it is used for.** Slack does
not divide search by conversation type, so a token that can search channels can
search direct messages too. `privacy.md` § 3.16 promises those are never read,
and with this scope granted that promise can no longer rest on the scope list —
it rests on `isDirect()` in `slack.ts`, which drops every direct and group
match, and treats a conversation it cannot positively identify as a channel as
direct. Anything that weakens that function breaks a published claim.

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

## Connect environments — and what production needs

Every Connect call carries `x-pd-environment`, set from `PIPEDREAM_ENVIRONMENT`
per Supabase branch. Sandbox is `development`; production has to be
`production`, and that is not a label.

`development` is capped at **10 external users**, and everyone connecting through
it must be signed in to pipedream.com. It is for our own testing, not for
customers — a real user who is not a Pipedream account holder simply cannot
finish the flow. Production access is enabled on Pipedream's pricing page, not
by flipping the variable.

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
| `user_may_use_provider(user, provider)` | may this person act in it? | `resolveConnection`, `proposal-execute`, `approve_proposal` |
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

**`org_allows_provider` is retired in place.** `20260827170000` moved its last
caller (`approve_proposal`) onto the shared rule and revoked its `authenticated`
grant — it took an arbitrary organization id, so any signed-in account could
enumerate any organization's policy. The function itself stays until a contract
migration can drop it.

**Retiring is a schema change, not a config one.** All three functions are
additive; dropping any of them means finding every caller above first.
