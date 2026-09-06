# Production rollout of the `integrations` migrations

_Last updated: 2026-09-06_

A one-off runbook: delete it once the push has happened and every box below
is ticked. `docs/supabase.md` stays the durable reference.

State of the work needed before the 142 migrations on `integrations` that
production does not have (255 in git + 4 added here, minus the 117 production
already carries) can be pushed to `lptqvnizjwglilgeukwx`. Nothing here has
been applied to production. The sandbox (`zdpvmwqauczsfwlgflas`) carries all
259 as of 2026-09-06.

## What was verified on 2026-09-06

- **The 117 migration files production has applied are byte-identical on
  `main` and `integrations`.** Six of them were edited after creation, all on
  the day they were written and before their release. The "41 shared versions
  with different hashes" in the audit is the CLI recording a file as N split
  statements while the branch deploy records it as one — a bookkeeping
  difference, not a content one. Confirm against production's
  `schema_migrations.statements` before the push (query below) rather than
  trusting this paragraph.
- **All 259 migrations apply cleanly from an empty database**
  (`supabase db reset --local`, 2026-09-06). This proves ordering and syntax,
  not behaviour on production data.
- **The sandbox schema equals the git schema except for known drift** (tables
  and columns compared by name, functions by signature, SECURITY DEFINER flag
  and `search_path`):

  | Object | Where | What it is |
  |---|---|---|
  | `meeting_shares.id`, `meeting_shares_id_key`, `share_product_events_share_id_fkey` | missing in sandbox only | dropped by hand; production is correct. Repaired by `20260906222300_a_share_keeps_its_id.sql`, a no-op on production |
  | `decks`, `create_deck`, `revoke_deck`, `get_shared_deck` | sandbox only | the decks feature from the `develop` git branch (`4d7f46a`), never on `integrations` or `main` |
  | `knowledge_events` (215 rows), `decisions` (50), `decision_events` (174), `match_knowledge_events` | sandbox only | in no git branch at all; created directly in the sandbox |
  | `list_my_pending_invites` | sandbox only | leftover of the abandoned workspaces overlay that `20260814104956_cleanup_abandoned_workspace_overlay.sql` did not drop |

  None of the sandbox-only objects can reach production: nothing in git
  creates them. They account for every Security Advisor delta the audit
  attributed to "new" surface: the 3 extra `anon` definer functions and 4 of
  the extra `authenticated` ones are the deck/invite functions, and 1 of the
  mutable-`search_path` functions is `match_knowledge_events`.

- **`_team_membership_grants_content(uuid, uuid)`** is called only from
  SECURITY DEFINER functions owned by `postgres` (`can_read_folder`,
  `can_read_meeting_via_grant`, `_meetings_granted_to_me`,
  `_meetings_shared_with`) and by no RLS policy or client, so
  `20260906222100` revokes it from `authenticated` without breaking a reader.
- **`private.connector_oauth_config` under RLS** breaks
  `custom_access_token_hook` unless `supabase_auth_admin` gets a policy: the
  hook is SECURITY INVOKER and that role does not bypass RLS. Verified locally
  both ways (with the policy the hook returns the connector `aud`; with it
  dropped in a transaction the hook fails with "query returned no rows").
  `20260906222200` enables RLS and adds that policy.
- **Production-data checks the audit already ran** (no `set not null`, no new
  unique index on an existing table, zero rows violating the incoming
  `check` constraints on `action_items.kind`, `usage_events.kind`, top-up
  SKUs, `usage_topups`; `pro_publishes_its_hours` grandfathers the five live
  Pro subscriptions before changing the plan) were not re-run here.

## Before the push

- [x] **Apply the four new migrations to the sandbox** — done 2026-09-06
      through the MCP write path, with the four versions recorded in
      `schema_migrations` byte-identical to the git files (md5 of
      `statements[1]` matches each file). Security Advisor afterwards: 163
      findings, down from 167 — mutable `search_path` is now only
      `match_knowledge_events`, no table in `private` lacks RLS, the
      `authenticated` definer count is 121, `anon` stays at 9 (6 canonical +
      the 3 deck functions below).

- [ ] **Decide the sandbox-only objects.** Recommended: drop
      `knowledge_events`, `decisions`, `decision_events`,
      `match_knowledge_events` and `list_my_pending_invites` in the sandbox
      (one-off, they exist in no branch), and leave `decks` to the `develop`
      branch that owns it. Until then the sandbox advisor will keep reporting
      them; they are not a production concern.

- [ ] **Clear `MIGRATIONS_FAILED` on the `develop` Supabase branch.** The
      status comes from the git-driven deploy of the `develop` git branch,
      whose migration set differs from what the sandbox instance actually
      holds (see `docs/supabase.md` § Branches). Check the branch's deploy
      log in the dashboard; the fix is usually vendoring the versions the
      instance has that the git branch lacks, never fast-forwarding `main`
      into `develop`.

- [ ] **Confirm production's recorded migrations match git.** Read-only,
      via the Management API with the `sbp_` PAT:

      ```sh
      curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        -H 'Content-Type: application/json' \
        https://api.supabase.com/v1/projects/lptqvnizjwglilgeukwx/database/query \
        -d '{"query":"select version, md5(regexp_replace(array_to_string(statements, chr(10)), ''\\s+'', '''', ''g'')) from supabase_migrations.schema_migrations order by version"}'
      ```

      Compare against the same expression over the git files (strip comments
      the way the CLI does, or diff the raw statements for the six files with
      more than one commit: `20260603120000`, `20260630130000`,
      `20260806120000`, `20260811142436`, `20260813072636`,
      `20260827081104`). Any real difference means production ran an older
      body and needs a forward migration for the delta — never an edit to
      the applied file.

- [ ] **Rehearse on a copy of production data.** The sandbox was created
      without data, so the backfills in `context_platform_backfill_*`,
      `pro_publishes_its_hours`, `the_pool_remembers_who_spent_it` and the
      `usage_events` constraint changes have never run against the real
      ~134k `usage_events` / ~112k transcript rows. Create a throwaway branch
      with data cloning (`supabase branches create rehearsal --with-data`,
      Pro plan; or a branch from a fresh production backup restore), push
      `integrations` to it, time the run, and delete the branch. Keep the
      timing: it is the maintenance window.

- [ ] **Enable leaked-password protection** on both instances. It is not a
      `config.toml` key in CLI 2.102; use the Management API:

      ```sh
      curl -s -X PATCH -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        -H 'Content-Type: application/json' \
        https://api.supabase.com/v1/projects/<ref>/config/auth \
        -d '{"password_hibp_enabled": true}'
      ```

      Nod signs in with Google (desktop) and email OTP (founder dashboard),
      so no user flow changes; this only closes the advisor finding.

- [ ] **Deploy order for the day.** Migrations first (`supabase db push`
      against `lptqvnizjwglilgeukwx`), then the Edge Functions that changed
      on `integrations` (`supabase functions deploy <name> --project-ref
      lptqvnizjwglilgeukwx` for each; git-driven deploys have missed
      functions before), then per-instance secrets from
      `docs/supabase.md` § Model routing, then the desktop release. Clients
      on 13.1.x keep working throughout: every contract change on the branch
      was written expand-first (`.agents/rules/backward-compatibility.md`).

- [ ] **Rollback.** Migrations are forward-only; the rollback for a bad
      push is the pre-push backup plus the previous Edge Function
      deployments. Take a manual backup (dashboard → Database → Backups, or
      `supabase db dump`) immediately before `db push` and note its
      timestamp here.

- [ ] Re-run the Security Advisor on production after the push and record
      the count here. Expected: the `authenticated` definer-function count
      rises by roughly 70 (every new RPC on the branch starts with its own
      `auth.uid()` check per `.agents/rules/supabase.md`), the `anon` count
      stays at 6, mutable `search_path` and RLS-off in `private` go to zero.

## Not done, on purpose

- No production query was run from this session. Every production fact
  above is either from git or from the audit that prompted this document.
