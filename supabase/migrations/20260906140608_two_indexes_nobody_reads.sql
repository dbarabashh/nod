-- Two indexes that only ever cost a write.
--
-- `usage_events_integration_user_idx` duplicated `usage_events_user_created_idx`
-- (same leading columns; the pool's `kind` and `org_id` predicates are cheap
-- heap filters after the seek) and was maintained on every transcribe row —
-- the table's hot path — for a query that runs once per entitlement resolve.
-- `usage_topups_org_period_idx` indexed a table with one row per purchase,
-- which the planner will scan whatever we build on it.

drop index if exists public.usage_events_integration_user_idx;
drop index if exists public.usage_topups_org_period_idx;
