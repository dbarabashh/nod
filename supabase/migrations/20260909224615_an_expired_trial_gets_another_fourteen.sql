-- Every expired trial is given another fourteen days, with its capture hours
-- reset to the full five.
--
-- The reactivation letter (`winback-release-reactivation-v1-en`) tells people
-- "your trial is back … it's already on your account, nothing to click". This
-- is what makes that sentence true, and it has to be applied before the letter
-- goes out or the letter is false.
--
-- Both dates move, not just the end. `monthly_usage_window` answers a trial with
-- `period_start = current_period_start` and `period_end = trial_ends_at`, and
-- consumed hours are summed over that window. Moving only `trial_ends_at` would
-- hand somebody fourteen days against a window that still contains every hour
-- they already spent — a reactivation that is out of hours on the day it lands.
--
-- `status` is not touched because there is no expired status to leave: every
-- trial row stays `trialing` and `resolve_entitlement` derives expiry by
-- comparing `trial_ends_at` to now. Moving the date is the reactivation.
--
-- Guards, each excluding a row this must not reach:
--   `trial_ends_at < now()`      — a live trial is not shortened or extended.
--   `paddle_subscription_id is null` — nobody who ever paid is turned into a
--                                  trialist; their period belongs to Paddle.
--   `plan = 'trial'`             — a plan change out of trial is not undone.
-- The permanent internal trial (`trial_ends_at` in 2099) is excluded by the
-- first guard, so its hand-set ceiling is left alone.
--
-- Not idempotent by design but safe to re-run: a second application finds every
-- row it touched sitting in the future and matches none of them.
--
-- Deploy order: this must land before the reactivation broadcast is sent. It
-- does not send anything itself — the letter is a deliberate, separate act.
--
-- Side effect worth knowing: these accounts resolve as `trialing` again, so the
-- activation campaigns that require a live trial can qualify them where they
-- have `lifecycle_guidance` consent and no prior claim for that campaign.
-- `email_send_claims` prevents any repeat, and `trial-learning-*` is keyed on
-- signup date rather than trial date, so none of those re-fire.

update public.subscriptions
   set current_period_start = now(),
       current_period_end   = now() + interval '14 days',
       trial_ends_at        = now() + interval '14 days',
       updated_at           = now()
 where status = 'trialing'
   and plan = 'trial'
   and trial_ends_at < now()
   and paddle_subscription_id is null;
