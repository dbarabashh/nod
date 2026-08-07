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

## CLI gotcha — management commands need a PAT

Management commands (`secrets set`, `branches …`) read a **Personal Access
Token** (`sbp_…`), not the `supabase login` keychain session — pass it inline
and target a branch with `--project-ref`:

```sh
SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref zdpvmwqauczsfwlgflas KEY=value
SUPABASE_ACCESS_TOKEN=sbp_… supabase branches update develop --git-branch develop --experimental
```

`db push` against a branch takes `--db-url` rather than `--project-ref`.
