# Inference cost controls

_Last updated: 2026-10-07_

Local implementation on `optimize-inference-costs`; not deployed. The October 7
OpenRouter export for the preceding 48 hours showed $5.855957 on the production
key and $0.918598 on development. The production `summary` category cost
$3.492376; 141,992 of its 171,966 output tokens were reasoning. These are dated
observations, not a prediction of future savings.

## Routing and reasoning

- The proxy disables reasoning for `summary` by default, including requests from
  older clients that explicitly request thinking. Sonnet remains the recap model.
- A server-only `SUMMARY_REASONING_EFFORT=low|medium` enables a quality experiment
  with at most 16,000 combined output tokens (a smaller client cap is preserved).
  Unset or invalid values disable it. `DISABLE_REASONING_TASKS=summary` wins over
  the experiment. Client recap effort preferences cannot bypass this policy.
- New desktop speaker naming, entity extraction, contextual recall and agent-draft calls use the
  existing utility slot. Its default is Mistral Small; environment overrides and
  the existing provider privacy/precision floor and fallback chain still apply.
  Semantic purpose determines the task even if users configure equal model IDs.
- Existing chat, transcription, title and utility policies are preserved. No
  blind cache markers are added to unique one-shot prompts. No hard production
  spending limit is introduced that would silently interrupt recordings.

## Attribution

The optional envelope-level `context` contains an allowlisted `purpose` and an
optional UUID `meeting_id`. It is outside the OpenRouter payload: old proxies
ignore it; new proxies validate it without forwarding it. The meeting ID is
client-supplied attribution, may refer to an unsaved draft, and grants no access.
Readers must scope usage by the authenticated user; never use this tag as an
ownership or authorization check.

`usage_events` gains nullable `purpose`, `meeting_id`, `reasoning_tokens` and
`cached_tokens`. Unknown counts stay null, while observed zero stays zero.
Reasoning is already included in completion tokens and must not be added twice.
Both buffered and streamed chat record the fields. Server completions additionally
record the generation ID and distillation meeting ID. Existing `model`, `task`,
cost and token column meanings do not change; actual model reporting should use
`coalesce(resolved_model, model)`.

Recap, streamed fallback and refinement carry the same meeting ID where available.
This identifies spend per meeting, but does not yet distinguish every transport
retry from every semantic refinement; do not call every `summary` row a recap.
Older clients still use the broad `summary` category and have null new metadata.

## Distillation

A new desktop makes one distillation transport attempt, rather than wrapping a
background job in the three-attempt interactive retry loop. The proxy preserves
upstream 429 as 429 and forwards Retry-After as seconds; failed attempts are still
metered. The desktop defers distillation for at least 60 seconds or the longer
provider delay, stops the current backfill batch, prevents overlapping calls for
the same meeting within a store, and backs off other per-meeting failures for five
minutes. Backfill resumes on a later launch; this change adds no background timer.
Cancellation now exits the shared retry sleep instead of firing another request.

Backfill filters the live draft sentinel (`ended_at == started_at`) and only processes ended meetings and explicitly asks the server to skip already
completed distillation. The check is owner-scoped. Legacy requests and intentional
regeneration remain able to process a completed meeting again. This is not a
cross-device distributed lock: simultaneous first-time requests can still race.

## Rollout and rollback

1. Apply `20261007114024_inference_cost_telemetry.sql` to the target environment.
   It only adds nullable columns, so old writers/readers keep working. No legacy
   path or column is retired and no temporary compatibility shim is introduced.
2. Deploy the functions importing the changed shared modules. At minimum this
   includes llm-proxy; use an import-graph review for other workers using
   complete.ts. New writers require the migration first to avoid losing usage rows.
3. Verify usage insertion, legacy payloads, streamed and buffered recap, utility
   fallback, and rate limiting in sandbox. Compare speaker/entity output and recap
   coverage on representative multilingual/long sessions before production rollout.
4. Release the desktop for finer attribution, helper routing and distill cooldowns.
   It can talk to the old proxy because context is envelope-level and the existing
   task labels and response formats are retained.
5. Rollback: restore function/client code and keep the additive columns. Do not
   drop columns while new writers may still run. Check server secrets when testing
   defaults: model overrides take precedence over the checked-in model table.

Provider production/development budgets and alerts live in OpenRouter, not in
this repository. They were not changed by this local implementation. A separate
stage limit should be chosen against the team's actual test budget.

## Local verification

- Deno policy and transport tests use synthetic responses, never paid model calls.
- Transport tests cover legacy/new clients, both response modes, telemetry,
  provider delay propagation and completed-backfill versus regeneration behavior.
- The additive SQL contract is tested on an isolated PostgreSQL 17 database using
  the historical usage table migrations before applying the new columns. This is
  a focused usage-schema upgrade test, not a replay of the entire Supabase stack.
- Desktop focused XCTest includes request metadata, retry classification and
  rate-limit delays. Actual model quality and realized savings require sandbox
  comparison and post-deploy observation; neither is claimed by unit tests.

## Verification result — 2026-10-07

- 34 focused Deno tests passed; `deno check` passed for llm-proxy and dependencies.
- macOS app built; 32 focused XCTest passed, including recap, speaker attribution,
  recall gates, wire context, cancellation classification and distillation schedule.
- Isolated PostgreSQL 17 usage-schema upgrade passed old/new writer checks,
  historical totals, unknown counters and unchanged RLS. The temporary database
  was removed afterwards. The upgrade script requires an isolated database;
  it is not an in-place test for an already-migrated application database.
- Two independent reviewers completed review/fix/re-review with no remaining
  P1/P2 findings. Fixed live-meeting timestamp sentinel handling, the remaining
  contextual-recall routing omission, missing agent meeting attribution and a
  race that could shorten a longer provider cooldown.
- Playbook structure validation and whitespace checks passed. No commits, pushes,
  migrations, secrets, provider budgets or functions were published/deployed.
