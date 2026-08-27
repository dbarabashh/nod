-- Retire the connections a Connect environment switch left behind.
--
-- Grants do not cross environments. Moving a branch from `development` to
-- `production` (or back) leaves every row in `integration_connections`
-- pointing at a broker account the new environment has never heard of: the
-- desktop client still draws "Connected", and every call comes back
-- `Auth provision owner mismatch`.
--
-- Not a migration, deliberately. Which environment a branch runs in is
-- operational, per-branch state — `supabase.md` keeps environment-specific data
-- out of `supabase/migrations/` for the same reason `plan_prices.paddle_price_id`
-- is seeded per branch. Run this once, by hand, against the branch whose
-- `PIPEDREAM_ENVIRONMENT` just changed.
--
-- Revoking fires `purge_provider_data`, which deletes what came with the grant
-- — a synced calendar, most visibly. That is correct: the grant is gone and the
-- data behind it can no longer be refreshed. People records survive on purpose;
-- past meetings and the audit log refer to them.
--
-- Afterwards everyone reconnects. Nothing else is needed: with the rows revoked,
-- `integration-reconcile` sees each provider as arriving and writes the fresh
-- account id.
--
--   SUPABASE_ACCESS_TOKEN=sbp_… \
--     curl -X POST "https://api.supabase.com/v1/projects/<ref>/database/query" \
--       -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
--       -H 'Content-Type: application/json' \
--       --data-binary @scripts/sql/retire-connections-after-environment-switch.sql

begin;

select provider, broker_account_id, user_id
  from public.integration_connections
 where revoked_at is null
 order by user_id, provider;

update public.integration_connections
   set revoked_at = now()
 where revoked_at is null;

commit;
