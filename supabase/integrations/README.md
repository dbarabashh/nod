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

**This app is not the one people currently authorize.** Connect defaults to
Pipedream's own OAuth client for every app in its catalogue, and that is what
every live connection has used so far — `oauth_app_id` is null on all of them.
So the screen a person reads today says *"Allow the Pipedream app to access
Slack"*, and the scopes it asks for are Pipedream's, not the curated set below.
The manifest is the ceiling we would ask for; right now nothing asks it.

The manifest is the exact shape Slack accepts — no comments, no extra keys, or
`apps.manifest.update` rejects the whole file with `invalid_manifest`.

**Applying a change.** An app configuration token comes from
[api.slack.com/apps](https://api.slack.com/apps) → *Your App Configuration
Tokens* → Generate. It expires in 12 hours.

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

Create one at Connect → OAuth Clients → New OAuth Client, or with
`pd oauth-client create`. Changing scopes afterwards makes everyone reconnect.

**What the scopes are for.**

| Scopes | Why |
|---|---|
| `channels:read`, `channels:history`, `channels:join`, `groups:read`, `groups:history` | Reading channels — `list_channels`, `read_channel`, `read_thread` in `functions/_shared/integrations/slack.ts`. `channels:join` is what lets Nod read a public channel nobody invited it to: Slack gives a bot no other way in, so the choice is between joining — which the channel sees — and not answering |
| `channels:manage`, `channels:write.invites`, `groups:write`, `groups:write.invites` | Opening a channel for what a meeting decided, and adding the people in it |
| `users:read`, `users:read.email` | Matching a colleague to their Slack account by address, for the organization directory |

Deliberately absent: `im:history`, `mpim:history` (direct messages), `files:*`,
`users:write`, `team.billing:read`, and `incoming-webhook` — the last one is
what made Slack demand a channel during installation for a webhook Nod never
uses.

**Scopes are declared twice.** Here, which is the ceiling of what the app may
ever ask for, and in whichever OAuth client actually runs the flow, which is
what it asks for this time.
That is OAuth's shape, not duplication of ours — but they have to agree, or the
authorization succeeds and the first API call fails with `missing_scope`.

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

Deploy order for the switch is the usual one — set the secret on the branch,
then redeploy the functions that read it (`integration-connect`,
`integration-reconcile`, `integration-action`, `integration-catalogue`,
`calendar-sync`, `directory-sync`, `proposal-execute`), because the value is
read at module load.
