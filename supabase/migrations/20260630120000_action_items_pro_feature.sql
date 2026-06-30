-- Make `action_items` (the per-meeting checklist + cross-meeting Action Items
-- aggregate) a Pro-tier capability. Plan → feature mapping is DATA in
-- `public.plans`, so unlocking a feature is an UPDATE here, never a client
-- release (see 20260608130000_entitlements.sql).
--
-- Granted on `trial` (the trial == the full Pro experience) and `pro`, NOT on
-- `starter`. Idempotent: the distinct-unnest keeps a re-run from duplicating
-- the array element.
update public.plans
set features = array(select distinct unnest(features || array['action_items']))
where plan in ('trial', 'pro');
