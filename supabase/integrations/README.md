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

The app is **Nod**, `A0BR09EJ62H`, in the Nod workspace. Nango runs the OAuth
dance and holds the credentials, which is why the redirect url is Nango's:
Slack refuses to return anybody to an address that isn't listed in the manifest.

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
`app_id`; it answers with the `client_id` and `client_secret` that go into the
Nango integration whose id is `slack`.

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
ever ask for, and in the Nango integration, which is what it asks for this time.
That is OAuth's shape, not duplication of ours — but they have to agree, or the
authorization succeeds and the first API call fails with `missing_scope`.
