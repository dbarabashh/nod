# Production rollout of the `integrations` migrations

_Last updated: 2026-09-09_

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

## Verified on 2026-09-09 (read-only production queries)

- **Production email is live, not gated.** `email_program_config.program_not_before`
  is `2026-08-14 22:00:00+00`, all 21 campaigns are `rollout_mode = 'live'`, and
  43 outbox rows are `accepted` — real lifecycle mail from 2026-08-17 to
  2026-09-09 12:03 UTC. `nod-playbook` and this file both claimed delivery was
  gated because the gate was null; that is true of the sandbox only. Nine
  template aliases have reached real users, `run-resend-worker-five-minute` and
  `scan-email-candidates-hourly` are both active.
- **Zero function drift in the email surface.** All seven live email functions
  (`email_campaign_qualification`, `enqueue_optional_email`,
  `optional_email_cooldown_clear` ×2 overloads, `email_outbox_send_guard`,
  `email_user_snapshots`, `enqueue_transactional_email`) md5-match the bodies
  built from the migrations production has applied. The NOD-91 manual repair
  does not touch them, so the `create or replace` in the pending email
  migrations is a clean upgrade from exactly the expected state.
- **Resend has no environment split.** One Resend account serves both
  instances, so template edits are live on production the moment they are
  published — they do not wait for a migration. The 2026-09-09 plain-letter
  restyle and the deletion of the eleven Ukrainian templates already apply to
  production mail. No production campaign referenced a `-uk` alias, so nothing
  broke.
- **Sender is inconsistent on production right now.** Template bodies sign
  "Dima" while the deployed `resend-worker` still hardcodes
  `From: Vlad from Nod <vlad@hellonod.app>`. Every production send until that
  function is redeployed carries the mismatch.
- **Optional mail lost its in-body opt-out.** The restyle removed
  `PREFERENCE_URL` from 26 template bodies. Production's
  `enqueue_optional_email` still populates the variable, so the
  `List-Unsubscribe` header still ships; only the visible link is gone.
- 92 accounts, 55 subscribed preferences, 18 signups in the last 14 days.

## Read-only pre-flight, 2026-09-09

Every statement below was checked against production with `select` only. The
pending set is now **153** migrations (was 142 on 2026-09-06), and **no
migration production has applied is missing from git** — the histories only
diverge forward.

Risky DDL inventory across those 153: 19 `add constraint … check`, 19 unique
indexes, 11 `add column … not null`, 1 foreign key, 3 `drop column`, 7
`drop table`, and **zero** `set not null` and zero column-type changes.

Of the 30 tables those statements touch, **only 8 exist on production today**;
the other 22 are created by the pending set itself, so they are empty when
their constraints are added and cannot fail. The eight that do exist all pass:

| Table | Rows | Checked | Result |
|---|---|---|---|
| `usage_events` | 149 043 | `usage_events_kind_check`, both the strict intermediate (`20260902233939`, no `integration`) and the final one | only `transcribe`/`chat`/`embed` present — both pass |
| `product_events` | 1 094 | all 18 distinct events against the incoming 41 client + 3 server allow-list; and that `product_events_event_check` exists to be dropped | no violating row; constraint present |
| `action_items` | 1 911 | 3 new checks, 2 `drop column` | new columns arrive NULL/defaulted so the checks pass; both drops are `if exists` and neither column exists here anyway |
| `meeting_shares` | 8 | `add column id` | `id` already present, so `20260906222300` is the no-op the audit predicted |
| `share_product_events` | 3 | `share_product_events_share_id_fkey` | 0 orphan rows |
| `usage_topups` | 0 | `usage_topups_grants_something` | empty, passes |
| `topup_checkout_intents` | 0 | `topup_checkout_intents_sku_check` ×4 | empty, passes |
| `app_config` | 1 | `add column live_room_required_build` | has a default |

`pro_publishes_its_hours` was also checked against live rows: 5 `pro`/`active`
subscriptions (3 with a hand-set ceiling the first UPDATE correctly skips, all 5
picked up by the `hours_are_unlimited` UPDATE), 4 `starter`/`active`, 2
`starter`/`canceled`, and 81 `trial`/`trialing` that neither UPDATE touches
because `trialing` is outside `('active','past_due')`. The audit's "five live
Pro subscriptions" is exact.

**No migration-time statement rewrites existing production data.** With
comments stripped and function bodies excluded, the pending set runs 24 data
statements at migration time and **zero `delete`, `truncate`, `disable row
level security`, `drop policy` or `grant … to anon`**. Every one of the 24 is an
`update`, and each either fills a column the same push adds (`meetings.origin`,
`meetings.room_key`, `meetings.ical_uid`, `profiles.active_org_id`,
`action_items.loop_state`, `action_items.evidence_idxs`,
`subscriptions.hours_are_unlimited`) or targets a table production does not have
yet (`integration_connections`, `org_members`, `source_objects`,
`action_proposals`, `calendar_events`). Pre-existing columns are read as
sources, never overwritten: 513 `action_items.evidence_idx`, 120 `done`,
5 Pro subscriptions.

The one apparent `delete from public.meetings` in `20260828105745` is inside a
comment. The one `create policy … using (true)` is
`private.connector_oauth_config` restricted to `supabase_auth_admin`, which is
the auth-hook fix the audit already described.

`20260905213308` looks like it undoes the Pro grandfathering and does not: it
removes `limit_overrides.hours_per_month` only where it equals the plan's own
value. After `20260905203754` a Pro subscription holds 40 against a plan of 20,
so the values differ and the override stays; a Starter override of 8 against a
plan of 8 is the redundant row it is meant to clear.

**The backfills do not run during the push.**
`20260903121908` only *creates* `backfill_meetings_into_source_objects`,
`backfill_calendar_events_into_source_objects`,
`backfill_ambient_into_source_objects` and
`backfill_session_embeddings_into_source_chunks` and grants them to
`service_role`. Nothing calls them. The migration is DDL only and instant; the
9 725-row embedding copy is a separate, deliberate step run afterwards, outside
any maintenance window. `source_chunks_vec_idx` (HNSW) is likewise built on an
empty table at `20260903120558`.

This removes the reason for a data-cloned rehearsal branch. The heaviest thing
left inside the push is validating a `check` constraint over 149 043
`usage_events` rows on a 187 MB database.

**What this does not prove:** how long the backfills take when someone does run
them. `source_objects` /
`source_chunks` are filled from 498 meetings and 9 725 `session_embeddings`
(47 MB), alongside 117 331 `meeting_transcripts` rows — correctness is now
argued from live data, duration is not. That still needs the
rehearsal below, and the duration is the maintenance window.

## What the pending email migrations change on a live production

- **The lever that holds the welcome letter is `is_enabled`, not
  `rollout_mode`.** `enqueue_transactional_email` selects on
  `email_class = 'transactional' and is_enabled`, and
  `email_campaign_rollout_allows` is only consulted by
  `email_campaign_qualification`, which returns early for transactional
  campaigns. Setting `rollout_mode = 'off'` on `welcome-founder` would do
  nothing at all.
- `20260909150048` + `20260909151227` start sending a welcome letter to every
  new signup — roughly one or two real people per day at the current rate —
  from the moment the migration lands, because the gate is already open and the
  campaign is transactional.
- `20260909170000` loosens a live cadence rule: the cooldown stops counting
  transactional sends, so subscribed users can receive more optional mail than
  they do today. This is the fix that makes day-1 reachable after a welcome
  letter, but it takes effect on real recipients immediately.
- `20260909163000` tightens `activation-at-risk` (no send when there are no
  open commitments) and adds usage counts to the payload. Fewer emails, not
  more.

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

- [x] **Confirm production ran the same code as git** — done 2026-09-09, and
      answered more directly than the hash comparison below. Rebuilding the
      expected state from only the 117 migrations production actually applied
      and md5-comparing every function body against live `pg_proc`:
      **60 of 60 application functions match exactly, zero drift.** The NOD-91
      manual repair left no trace in any function this covers.

      The `schema_migrations.statements` hash comparison could not be
      reproduced by hand (best normalisation matched 17/113); the CLI stores
      parser output, not the file text, so that check needs the CLI's own
      hashing and is not worth chasing now that the semantic check is clean.
      Note four versions carry NULL `statements` on production
      (`20260628120000`, `140000`, `160000`, `180000`) — applied by the branch
      deploy path, which records none.

- [ ] ~~**Confirm production's recorded migrations match git.**~~ Read-only,
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

- [ ] ~~**Rehearse on a copy of production data.**~~ Superseded by the
      2026-09-09 pre-flight: the backfills are not part of the push, and every
      constraint was probed against live rows. Re-run `supabase db reset
      --local` instead — 11 migrations have been added since the 2026-09-06
      run, so that ordering proof is stale.

- [ ] ~~(original)~~ **Rehearse on a copy of production data.** The sandbox was created
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
