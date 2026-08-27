# Working with Supabase

**Always use the Supabase CLI** for anything that touches the Supabase project
— schema, functions, secrets, local dev. Don't change things in the dashboard
if the change should live in code, and don't hand-roll SQL outside the
migrations directory.

```sh
# Schema changes — always via migrations, never via dashboard SQL editor:
supabase migration new <name>            # creates a new timestamped migration file
supabase db push                          # apply local migrations to the linked project
supabase db reset                         # rebuild local DB from migrations (dev only)

# Edge Functions — source lives in supabase/functions/<name>/:
supabase functions deploy <name>
supabase functions serve <name>           # local dev with hot reload

# Secrets (server-side env vars used by Edge Functions):
supabase secrets set OPENROUTER_API_KEY=sk-or-v1-...
supabase secrets list

# Local dev stack:
supabase start
supabase stop
```

The project is already linked (`supabase/config.toml`) to ref
`lptqvnizjwglilgeukwx`, so CLI commands target the right project automatically.

## Connector OAuth and previews

The OAuth server configuration is committed in `supabase/config.toml` but ships
disabled. The custom access-token hook is installed by migration and only
changes tokens that contain `client_id`: it sets the exact MCP resource as
`aud`, grants only `meetings:read`, and assigns the no-direct-access
`mcp_connector` role. Dynamic client registration and PKCE S256 are used by
ChatGPT; Anthropic can use hosted pre-registered credentials if review requires
them. Refresh-token reuse detection and rotation remain enabled in Auth config.

Test connector migrations against the pull request's Supabase Preview branch,
not the divergent long-lived `develop` branch. For preview ref `<preview-ref>`:

```text
resource: https://<preview-ref>.supabase.co/functions/v1/mcp
issuer:   https://<preview-ref>.supabase.co/auth/v1
consent:  the nod-landing Vercel preview /oauth/consent URL
```

Set the Edge Function environment per preview or production deployment:

```sh
supabase secrets set --project-ref <ref> \
  MCP_OAUTH_ENABLED=false \
  MCP_RESOURCE_URI=https://<ref>.supabase.co/functions/v1/mcp \
  MCP_AUTHORIZATION_SERVER=https://<ref>.supabase.co/auth/v1 \
  MCP_RESOURCE_METADATA_URI=https://<landing-host>/.well-known/oauth-protected-resource \
  MCP_APP_ASSET_ORIGIN=https://<landing-host> \
  MCP_APP_DOMAIN=https://<landing-host> \
  MCP_MIGRATION_URL=https://<landing-host>/connectors
```

Keep `MCP_OAUTH_ENABLED=false` until both deployments are live. Enable the
Supabase OAuth server and the function kill switch only for private smoke tests,
then set `official_connectors_enabled` and a 90-day
`legacy_pat_sunset_at`/`LEGACY_MCP_PAT_DISABLE_AFTER` when a listing becomes
public. Rollback is disabling OAuth and the function switch while leaving the
legacy path available until its configured sunset.

## Branches — sandbox (`develop`) vs production (`main`)

We use [Supabase
Branching](https://supabase.com/docs/guides/deployment/branching) (Pro plan) to
keep development off live data. Two long-lived branches, each a **fully
isolated instance** — its own database, Edge Functions, API keys, secrets, and
auth config:

| | git branch | Supabase ref | URL | Paddle |
|---|---|---|---|---|
| **Production** | `main` | `lptqvnizjwglilgeukwx` | `api.hellonod.app` (custom domain) | live |
| **Sandbox (dev)** | `develop` (persistent) | `zdpvmwqauczsfwlgflas` | `https://zdpvmwqauczsfwlgflas.supabase.co` | sandbox |

- **The client picks the environment by build config.** `SupabaseConfig` is
  `#if DEBUG` → the `develop` branch (sandbox), `#else` → production. A Debug
  build exercises the whole stack — auth, billing, LLM proxy — against sandbox
  data without ever touching live.
- **Deploys are git-driven.** Pushing to a branch's git branch (for `develop`,
  via its open PR) makes Supabase apply new **migrations** and deploy **changed
  Edge Functions** to that branch's instance. Caveat seen in practice: it only
  redeploys functions whose files changed and has missed one — the
  deterministic fallback is `SUPABASE_ACCESS_TOKEN=sbp_… supabase functions
  deploy <name> --project-ref zdpvmwqauczsfwlgflas`.
- **Nothing is inherited from prod automatically.** Secrets (`PADDLE_API_KEY`,
  `PADDLE_WEBHOOK_SECRET`, `OPENROUTER_API_KEY`, …) and **OAuth providers**
  (Google) must be set **per branch**. `SUPABASE_URL`/`ANON_KEY`/
  `SERVICE_ROLE_KEY` are auto-injected. For Google sign-in on a branch you must
  also add the branch's `…supabase.co/auth/v1/callback` to the Google Cloud
  OAuth client and allowlist `nod://auth-callback` in the branch's auth URL
  config.
- **Environment-specific DATA is seeded per branch, not via migrations.**
  Values that differ between sandbox and live — notably
  `plan_prices.paddle_price_id` — are set with a one-off `UPDATE` against each
  branch (migrations only seed `pri_REPLACE_*` placeholders), so sandbox price
  ids never ship to prod.
- **`main` and `develop` migration histories can legitimately diverge — don't
  blind-sync them.** Each branch's Supabase instance keeps its own
  `supabase_migrations.schema_migrations` history, and in-flight work lands on
  one before the other: prod carries the `founder_dashboard` migrations
  (applied from the separate founder-dashboard project), while the sandbox
  carries not-yet-merged feature migrations (`workspaces`, `decks`, …). The
  **"Supabase Preview" check fails on _every_ push — DB change or not** —
  whenever a branch's remote history has versions absent from that git branch's
  `supabase/migrations/` ("Remote migration versions not found in local
  migrations directory"). Fix by **vendoring the missing migrations into the
  matching git branch only**: fetch each byte-faithfully from the branch DB's
  `schema_migrations` via the Management API (`POST
  /v1/projects/<ref>/database/query` with the `sbp_` PAT) → `jq -j '.sql'` to a
  file → md5-verify against `md5(statements[1])`. Do **not** fast-forward
  migrations from `main` into `develop` (or vice-versa) — that pushes one env's
  schema onto the other's sandbox, which then tries to apply it.

## Model routing secrets — what to set at the next prod release

`_shared/model-policy.ts` decides which model serves which task. Each task reads
one secret (`SUMMARY_MODEL`, `TITLE_MODEL`, `UTILITY_MODEL`, `CHAT_MODEL`); an
unset variable means "no policy" and the client's own default is used unchanged.
`DISABLE_REASONING_TASKS` is a comma-separated task list whose reasoning the
proxy forces off — the client can only do that for `utility`.

**Production carries no model overrides today.** Every task runs the client
default, which is why `usage_events` shows `requested_model = resolved_model` on
every row.

The order matters, because one step gates the others:

1. **Ship the client fix first.** Until `290f08b` reaches `main` and a build
   goes out, summary/recap/entity calls are all labelled `title`, so
   `SUMMARY_MODEL` controls nothing and `TITLE_MODEL` controls four different
   jobs at once. Verify by looking for `task = 'summary'` rows in prod
   `usage_events`; there are none before that build.
2. **Deploy `llm-proxy`** — a secret is injected at isolate boot, so a warm
   instance keeps serving the old value until it cycles. Deploy during a quiet
   window: `usage_events` shows live traffic, and a `utility` call every ~40s
   means someone is mid-meeting.
3. **Then set the secrets**, sandbox first, verified on real traffic:

```sh
SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref <ref> \
  UTILITY_MODEL=google/gemini-2.5-flash-lite
```

Verified on sandbox 2026-08-27: `utility` resolved to
`google/gemini-2.5-flash-lite`, HTTP 200, 5 completion tokens, billed at list
price with no failover. Roughly 11x cheaper than `claude-haiku-4.5` on the same
prompts.

Rollback is `supabase secrets unset --project-ref <ref> UTILITY_MODEL`; routing
returns to the client default on the next isolate.

### Why routing a task is safe to try

Two independent nets, both already in the code:

- Every `utility` call site catches and degrades — HyDE falls back to the raw
  query, the session router to a corpus-wide search, the live analyst skips a
  tick, loop resolution and lookup return empty. None of them can fail a
  recording, a transcript or a summary.
- `applyModelPolicy` keeps the client's chain behind the override, so the
  payload carries `[<override>, claude-haiku-4.5, claude-sonnet-4.6]` and
  OpenRouter retries down it on any upstream failure.

One gap to watch: `providerPreference` is built from the *client's* model, so
the `google-vertex` preference that exists to dodge AI Studio's shared free-tier
429s is not applied to a server-routed `google/` model. Sandbox calls billed at
the paid rate, so it is not currently biting; if 429s or failovers appear on a
Gemini task, move that preference into `applyModelPolicy`.

## CLI gotcha — management commands need a PAT

Management commands (`secrets set`, `branches …`) read a **Personal Access
Token** (`sbp_…`), not the `supabase login` keychain session — pass it inline
and target a branch with `--project-ref`:

```sh
SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref zdpvmwqauczsfwlgflas KEY=value
SUPABASE_ACCESS_TOKEN=sbp_… supabase branches update develop --git-branch develop --experimental
```

`db push` against a branch takes `--db-url` rather than `--project-ref`.

## Realtime — broadcast from the database

Access changes (a folder shared or unshared, a membership granted or removed)
reach other Macs as a **Broadcast** message sent from a trigger, not as a
Postgres Changes subscription. Topics are `user:<uuid>`, `org:<uuid>` and
`team:<uuid>`; the policy on `realtime.messages` in
`20260815100636_broadcast_access_changes.sql` decides who may listen to which.
`user:` is the one that matters most — you pass its policy whether or not you
are still in the organization, so the message telling you that you were removed
is one you are still entitled to receive.

Two things about this cost an hour to find, and neither is in Supabase's docs.

**`realtime.messages` is partitioned by date, and the partitions are created by
the Realtime service itself — not by a migration and not by `pg_cron`.** A
project where nobody has ever opened a Realtime connection has *zero*
partitions, so every send fails with `no partition of relation "messages" found
for row`. The service creates several days' worth the first time a client
connects. You cannot create them by hand: `realtime` is a managed schema and
even `postgres` gets `permission denied for schema realtime`.

**That failure is silent.** `realtime.send` wraps its insert in `EXCEPTION WHEN
OTHERS THEN RAISE WARNING`, so a failed send returns normally and logs nothing
you will see. If broadcast appears to do nothing, check for partitions first:

```sql
select c.relname
  from pg_class c
  join pg_inherits i on i.inhrelid = c.oid
  join pg_class p on p.oid = i.inhparent
  join pg_namespace n on n.oid = p.relnamespace
 where n.nspname = 'realtime' and p.relname = 'messages';
```

Empty means nothing has ever connected. Open the app once and look again.

**Production has the same empty state** until the first client connects there,
which will be the first Release build carrying the subscription. Check the query
above right after that ships — until it returns rows, every access change is
being dropped, and the swallowed error means nobody will notice.

## NOD-76 rollout — pricing, referrals, communications

Everything from NOD-76 lands **dark**. Nothing below changes what a customer sees
until the explicitly listed switch is thrown, and the pricing switch needs a
recorded founder decision first (NOD-76 forbids treating implementation as
approval).

### What is off by default

| Switch | Default | What it gates |
|---|---|---|
| `plan_prices.available_for_new_checkout = false` on the replacement rows | **thrown on prod 2026-08-12** | The new catalog and the top-up. `create-checkout` also refuses any `pri_REPLACE_*` id outright. Sandbox is still dark. |
| `app_config.meeting_lease_required_build = 2147483647` | dark | Chunk-level lease enforcement. Start-time allowance still applies to any build that speaks the protocol. |
| `email_program_config.program_not_before is null` | dark | **All** Resend traffic — optional email, transactional referral notices, and contact sync alike. The communications-v2 migration resets this gate. |
| `email_campaigns.rollout_mode = 'off'` | dark | Each optional lifecycle, activation, win-back, or research campaign independently. |

`select public.email_rollout_readiness();` answers "can this branch send yet" and
reports gate state, vault secrets, schedules, queue depth, and whether any
placeholder price is exposed.

### Sandbox order of operations

Sandbox is `zdpvmwqauczsfwlgflas`. Do it in this order — each step is safe on its
own, and the order is what keeps it safe.

1. **Secrets** (per branch, nothing is inherited from prod):

   ```sh
   SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref zdpvmwqauczsfwlgflas \
       INTERNAL_JOB_SECRET=… RESEND_WEBHOOK_SECRET=… \
       RESEND_PRODUCT_UPDATES_TOPIC_ID=… RESEND_LIFECYCLE_GUIDANCE_TOPIC_ID=… \
       RESEND_FOUNDER_RESEARCH_TOPIC_ID=…
   ```

   `PADDLE_API_KEY`, `PADDLE_REFERRAL_DISCOUNT_ID`, `PADDLE_WEBHOOK_SECRET` and
   `RESEND_API_KEY` are already set on sandbox.

2. **Vault** — `supabase_project_url` and `internal_job_secret`. Without them
   `invoke_internal_edge_job` returns null and the two edge-job schedules do
   nothing, deliberately quietly, instead of failing every five minutes.

3. **Migrations** — `db push --db-url <sandbox>`. They are additive.

4. **Functions** — deploy `llm-proxy`, `paddle-webhook`, `create-checkout`,
   `export-account` (changed) and `create-topup-checkout`, `billing-jobs`,
   `resend-worker`, `resend-webhook`, `email-preferences` (new). Deploy
   `llm-proxy` **before** running a client build that speaks the lease protocol:
   an old proxy answers `meeting_start` with 400 and recording will not start.

5. **Paddle sandbox destination** — subscribe the webhook to
   `transaction.completed` and `adjustment.created` / `adjustment.updated`. Today
   it carries only `subscription.*`, which is why top-up fulfilment, referral
   activation and paid conversions cannot fire at all.

### Sandbox Paddle catalog (created 2026-08-11, dark)

| SKU | Sandbox price id |
|---|---|
| `starter_monthly_usd_15` | `pri_01kzrzfe1t8vp09pr5yzwbb963` |
| `starter_yearly_usd_144` | `pri_01kzrzfecpkd01vv1c2dxfg9rx` |
| `pro_monthly_usd_24` | `pri_01kzrzfeh9zz5ktv8xbg7xh385` |
| `pro_yearly_usd_240` | `pri_01kzrzfen6m04m7y6awxvb1wj0` |
| `starter_5h_usd_12` | `pri_01kzrzferwv9jdt9k71r79jf50` |

The referral discount `dsc_01kw78at3qrb1zq5y561da9t9t` (50%, one period,
`enabled_for_checkout = false`) is restricted to **both** the legacy and the new
Pro monthly price, so referral checkout works either side of a cutover. Restricting
it to only one of them breaks the other: Paddle rejects a transaction whose item
the discount does not cover, and `create-checkout` then fails closed with 503.

Cutover, once (and only once) the pricing decision is recorded:

```sql
select public.cutover_pricing_catalog(
    'pri_01kzrzfe1t8vp09pr5yzwbb963', 'pri_01kzrzfecpkd01vv1c2dxfg9rx',
    'pri_01kzrzfeh9zz5ktv8xbg7xh385', 'pri_01kzrzfen6m04m7y6awxvb1wj0',
    'pri_01kzrzferwv9jdt9k71r79jf50'
);
```

It validates the ids, refuses to repurpose one that already means something else,
and leaves every superseded price `active` (so renewals still resolve a plan) but
no longer offerable.

### Secrets: what is already set (2026-08-11)

Both branches now carry the full set — `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`,
the three `RESEND_*_TOPIC_ID`s, `INTERNAL_JOB_SECRET`, and the three Paddle
secrets. Setting them ahead of the deploy is inert: no function reads them until
it exists, and nothing sends until the program gate opens.

| | Sandbox `zdpvmwqauczsfwlgflas` | Production `lptqvnizjwglilgeukwx` |
|---|---|---|
| Resend API key | shared account key | dedicated `nod-prod-supabase` (full access — the worker reads templates and contacts, not just `POST /emails`) |
| Resend webhook | `91281828-5acb-46f4-9052-7178697b5ef0` | `c6f22e65-99fe-4995-8699-852d80d2f492` |
| `INTERNAL_JOB_SECRET` | branch-specific | branch-specific (different value) |

Both webhooks point at their own branch's `resend-webhook` and subscribe to
`email.delivered`, `email.failed`, `email.bounced`, `email.complained`,
`email.suppressed`, and `contact.updated`. Resend webhooks are **account-wide**,
not per-domain: once sending starts, both endpoints receive every event, and each
records the ones whose provider id exists in its own database. A signing secret is
shown once at creation and cannot be read back, so it lives only in the branch's
Supabase secrets.

Still to do at deploy time, deliberately not done ahead:

- **Vault** on each branch: `supabase_project_url` and `internal_job_secret`
  (the same value as the branch's `INTERNAL_JOB_SECRET`). Sandbox has both;
  production does not, on purpose — with an empty vault
  `invoke_internal_edge_job` returns null and stays silent, so the schedules that
  arrive with the migrations cannot hammer functions that are not deployed yet.
- **Verify the live referral discount.** Production already has
  `PADDLE_REFERRAL_DISCOUNT_ID`. Its `restrict_to` must list the live Pro monthly
  price — Paddle rejects a transaction whose item the discount does not cover, and
  `create-checkout` then fails closed with `503 referral_unavailable`. This is the
  same trap already defused in sandbox by listing both the legacy and the new Pro
  monthly price.

### Opening the email gate

`select public.configure_email_policy_gate('<policy publication timestamp>');`
sets `program_not_before` to publication + 30 days — the CHECK constraint will not
accept anything shorter. The clock starts when the policies are **published on
hellonod.app**, so publishing them is the long-lead item, not the code.

The gate is necessary but not sufficient. Every optional campaign also starts
with `rollout_mode = 'off'` and moves independently through `seed`, `limited`,
then `live`. Seed sends only to explicit `email_rollout_members`; limited sends
at most two customer emails per rolling 24 hours. The worker rechecks consent,
qualification, suppression, deduplication, the policy gate, and rollout mode at
send time. Resend open and click tracking must both remain disabled.

`communications-v1` consent remains valid only for the purpose and cadence the
person originally accepted: product offers, ordinary lifecycle nudges no more
than once per 14 days, or founder research no more than once per 30 days. Trial
learning on days 1, 4, and 10 requires a new `communications-v2` lifecycle
opt-in. Existing v1 lifecycle subscribers receive one non-blocking, unchecked
upgrade prompt; dismissing it does not change their v1 choice. Country is never
used as a substitute for consent.

Before opening it: the preference page at `hellonod.app/email-preferences` has to
exist (every optional email links to it), and the legacy Resend topic
"Product updates — legacy" (default `opt_in`) has to be archived, or a broadcast
could reach people who never gave the new consent.
