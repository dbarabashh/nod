-- Three functions with no caller.
--
-- Each was granted and then never asked — not by a migration, a policy, a
-- trigger, a view, an edge function, a cron job, the desktop client, the
-- dashboard or the web viewers. The repo's rule is that an abstraction earns
-- its place with callers, and a `security definer` function that nothing
-- calls is surface with no reader to notice when it goes wrong.
--
--   * `person_identity_for` (`20260816220000`)
--   * `is_team_member` (`20260814111629`)
--   * `google_analytics_sync_readiness` (`20260813072636`, `20260814111104`)
--
-- Two of them were granted to `authenticated` and so reachable over
-- PostgREST, but no released desktop build, dashboard or web viewer has ever
-- named either — the history of every client repository is clean — so there
-- is no legacy traffic to wait out before dropping them.
--
-- Rollback is the original `create function` from each migration named above.

drop function if exists public.person_identity_for(uuid, text);
drop function if exists public.is_team_member(uuid);
drop function if exists public.google_analytics_sync_readiness();
