-- `trial_reactivations` is filled from the shape the reset left, not from the
-- clock.
--
-- `20260909230500` reconstructed the membership with a hardcoded one-minute
-- window, on the assumption that the reset had run at the same moment
-- everywhere. It had not: sandbox applied `20260909224615` at 22:46 and
-- production at 22:49, so the window matched every reactivated account on one
-- branch and none on the other — a campaign that would have qualified nobody,
-- silently, on the only branch that matters.
--
-- The reset wrote three columns in one statement, and their relationship is its
-- signature: `current_period_end = current_period_start + 14 days` and
-- `trial_ends_at = current_period_end`. Nothing else in the schema produces it —
-- a trial that has been live all along carries a null `current_period_end`, and
-- the 62 reactivated rows carry the shape while the 19 untouched ones do not.
-- Reading the signature instead of the timestamp makes this correct on any
-- branch and on a fresh environment, and it stays correct if the reset is ever
-- re-run.
--
-- Idempotent: `on conflict do nothing`, and the sandbox row the previous
-- migration already inserted is left as it is.

insert into public.trial_reactivations (user_id, reactivated_at)
select s.user_id, s.current_period_start
  from public.subscriptions s
 where s.plan = 'trial'
   and s.status = 'trialing'
   and s.paddle_subscription_id is null
   and s.current_period_end is not null
   and s.trial_ends_at = s.current_period_end
   and s.current_period_end = s.current_period_start + interval '14 days'
on conflict (user_id) do nothing;
