-- Make the in-meeting live "Ask" box (`ask_live`) a Pro-tier capability. The
-- box answers free-form questions about the running transcript while recording;
-- it's the premium in-meeting surface, above the free quick pills. Plan →
-- feature mapping is DATA in `public.plans`, so unlocking it is an UPDATE here,
-- never a client release (see 20260608130000_entitlements.sql).
--
-- Granted on `trial` (the trial == the full Pro experience) and `pro`, NOT on
-- `starter`. Idempotent: the distinct-unnest keeps a re-run from duplicating
-- the array element.
update public.plans
set features = array(select distinct unnest(features || array['ask_live']))
where plan in ('trial', 'pro');
