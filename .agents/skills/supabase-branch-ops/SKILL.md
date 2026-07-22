---
name: supabase-branch-ops
description: Operate the Supabase sandbox (develop) and production (main) branches — set per-branch secrets, deploy an edge function that git-driven deploys missed, apply migrations to the right instance, or fix the "Supabase Preview" check failing on every push. Use for any branch-scoped Supabase operation.
---

# Supabase branch operations

Two long-lived, **fully isolated** instances — separate DB, functions, keys,
secrets, and auth config:

| | git branch | ref |
|---|---|---|
| Production | `main` | `lptqvnizjwglilgeukwx` |
| Sandbox | `develop` | `zdpvmwqauczsfwlgflas` |

The client picks one by build config (`#if DEBUG` → sandbox). Background:
`docs/supabase.md`.

## Auth — the gotcha that wastes the most time

Management commands (`secrets set`, `branches …`) read a **Personal Access
Token** (`sbp_…`), *not* the `supabase login` keychain session. Pass it inline
and always target the branch explicitly:

```sh
SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref zdpvmwqauczsfwlgflas KEY=value
SUPABASE_ACCESS_TOKEN=sbp_… supabase branches update develop --git-branch develop --experimental
```

The PAT is in `.claude/settings.local.json` under `env`. `db push` to a branch
takes `--db-url`, not `--project-ref`.

## Common operations

- **Secret didn't take effect** — nothing is inherited from prod. Set it on the
  branch itself, then redeploy the function that reads it.
- **Edge function didn't deploy** — git-driven deploys only redeploy functions
  whose files changed, and have missed one. Deterministic fallback:
  `SUPABASE_ACCESS_TOKEN=sbp_… supabase functions deploy <name> --project-ref <ref>`.
- **Google sign-in broken on a branch** — add that branch's
  `…supabase.co/auth/v1/callback` to the Google Cloud OAuth client and allowlist
  `nod://auth-callback` in the branch's auth URL config.
- **Paddle price ids wrong** — environment-specific data is seeded per branch
  with a one-off `UPDATE`, never via migration. Migrations only carry
  `pri_REPLACE_*` placeholders.

## "Supabase Preview" check fails on every push

It fails DB-change or not, whenever the branch's *remote* migration history has
versions absent from that git branch's `supabase/migrations/` ("Remote migration
versions not found in local migrations directory").

Fix by **vendoring the missing migrations into the matching git branch only**:

1. Query the branch DB's `supabase_migrations.schema_migrations` through the
   Management API: `POST /v1/projects/<ref>/database/query` with the `sbp_` PAT.
2. Write each missing version out byte-faithfully: `jq -j '.sql' > supabase/migrations/<version>_<name>.sql`.
3. Verify with md5 against `md5(statements[1])` from the same row.

**Never fast-forward migrations from `main` into `develop` or vice-versa.** The
histories legitimately diverge (prod carries `founder_dashboard` migrations;
sandbox carries unmerged feature migrations), and syncing pushes one
environment's schema onto the other's instance.
