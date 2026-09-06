-- Teams goes in the catalogue.
--
-- Two seat prices, monthly and yearly. `display_amount` is the per-seat figure
-- the paywall prints, and the yearly row carries its monthly equivalent for the
-- same reason every other yearly row does — both cycles then print the same
-- shape and the "billed yearly" line underneath carries the difference.
--
-- The three-seat minimum is enforced by Paddle on the price itself rather than
-- here, because it is a purchasing rule and not a fact about the plan. It exists
-- to stop Teams undercutting Pro: one seat at $39 for 25 pooled hours against
-- Pro at $29 for 25 would make a solo heavy user buy Teams and never buy an hour
-- pack.
--
-- Placeholders, as always — real Paddle ids are set per branch by a one-off
-- UPDATE, and the `plan_prices` policy for `authenticated` hides a row that is
-- not `available_for_new_checkout`, so nothing reaches a client until the price
-- genuinely exists.

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, available_for_new_checkout
) values
    ('pri_REPLACE_teams_monthly_39', 'teams', 'monthly', 'subscription', 39, 'USD', false, 17, true, 'teams_monthly_usd_39', null, false),
    ('pri_REPLACE_teams_yearly_384', 'teams', 'yearly',  'subscription', 32, 'USD', false, 18, true, 'teams_yearly_usd_384', null, false)
on conflict (paddle_price_id) do nothing;
