-- MRR counts only subscriptions Paddle is billing.
--
-- `founder_monetization()` summed `plan_prices.display_amount` over every
-- `active` and `past_due` subscription and, when the price id did not resolve,
-- substituted the plan's cheapest monthly price. That put three things into
-- "MRR" that are not recurring revenue:
--
--   1. `past_due` — a failed or paused charge, not money received. (The webhook
--      maps Paddle `paused` and any unknown status to `past_due` too.)
--   2. Subscriptions with no `paddle_subscription_id` — manual or complimentary
--      access, which nobody is paying for.
--   3. Paddle-backed subscriptions whose price id is retired or unset, valued
--      at a guessed list price.
--
-- `mrr_usd` now means: active, Paddle-backed, price resolved in `plan_prices`.
-- `display_amount` is already the monthly equivalent (a $288 year is 24), so
-- yearly plans are normalised by the catalogue, not here. Discounts are not
-- applied: the database holds no discount per subscription, so list price is
-- the only figure that can be defended.
--
-- Two populations, named apart. `paying_users`, `trial_to_paid_pct` and
-- `churn_rate_pct` keep counting ACCESS — every active/past_due row, manual
-- included — so existing readers do not move. `mrr_usd`, `arpu_usd` and
-- `new_paying_30d` (hence `cac_usd`) are built from the PADDLE population only,
-- so a hand-granted plan cannot lower CAC. `ltv_est_usd` still divides Paddle
-- ARPU by the access-population `churn_rate_pct`, and `gross_margin_pct`
-- subtracts the whole fleet's `cost_30d`: both are fleet inputs by design.
--
-- Everything else gets a key of its own so the gap between the old and the new
-- number is visible instead of vanishing. Manual access is reported at the
-- plan's lowest active subscription price across cycles (a floor), never
-- altered. A Paddle row whose trial has lapsed but whose webhook has not yet
-- moved it is `trial_expired`: it is in `trial_expired_users` and in no money
-- bucket, so the buckets do not tie out to the row count by design.
--
-- Realised money: the database records no subscription payments. The only
-- cash it knows is one-time packs in `usage_topups`, reported as
-- `topup_revenue_30d_usd` for PERSONAL purchases (`org_id is null`).
-- Subscription cash needs a payments ledger fed by `transaction.completed`,
-- which does not exist yet.
--
-- Organization billing (`org_subscriptions`, workspace packs) is a separate
-- payer and is not in these numbers.
--
-- `search_path` is empty and every relation is qualified, matching
-- `resolve_entitlement`: with `public` on the path an implicit `pg_temp` sits
-- in front of it and a caller's temp table could shadow a product table.
--
-- Compatibility: every previous key is still returned; only values change, and
-- only the dashboard reads them. Deploy order: this migration first, then the
-- dashboard — the new cards add keys the old function does not return.
-- Rollback: re-apply the body of `20260723110215`'s function.

create or replace function public.founder_monetization()
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  result jsonb;
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
  paying bigint;
  trialing bigint;
  trial_expired bigint;
  churned bigint;
  mrr numeric;
  mrr_subs bigint;
  mrr_unpriced bigint;
  mrr_past_due numeric;
  mrr_past_due_subs bigint;
  mrr_trialing numeric;
  mrr_trialing_subs bigint;
  manual_subs bigint;
  manual_list numeric;
  topup_30d numeric;
  cost_30d numeric;
  active_30d bigint;
  spend numeric;
  lifetime_months numeric;
  new_paying_30d bigint;
  churn_rate numeric;
  arpu numeric;
  ltv numeric;
begin
  perform public._assert_founder();

  select count(*) into total_users from auth.users u where u.id <> all(excl);

  select
    count(*) filter (where st in ('active', 'past_due')),
    count(*) filter (where st = 'trialing'),
    count(*) filter (where st = 'trial_expired'),
    count(*) filter (where st in ('canceled', 'expired'))
  into paying, trialing, trial_expired, churned
  from (select public._effective_sub_status(s.status, s.trial_ends_at) st
        from public.subscriptions s where s.user_id <> all(excl)) e;

  select count(*) into new_paying_30d from public.subscriptions s
    where s.status in ('active','past_due') and s.user_id <> all(excl)
      and s.paddle_subscription_id is not null
      and s.converted_at > now() - interval '30 days';

  select
    coalesce(sum(e.amount) filter (where e.st = 'active' and e.paddle and e.amount is not null), 0),
    count(*) filter (where e.st = 'active' and e.paddle and e.amount is not null),
    count(*) filter (where e.st = 'active' and e.paddle and e.amount is null),
    coalesce(sum(e.amount) filter (where e.st = 'past_due' and e.paddle and e.amount is not null), 0),
    count(*) filter (where e.st = 'past_due' and e.paddle),
    coalesce(sum(e.amount) filter (where e.st = 'trialing' and e.paddle and e.amount is not null), 0),
    count(*) filter (where e.st = 'trialing' and e.paddle),
    count(*) filter (where e.st in ('active', 'past_due') and not e.paddle),
    coalesce(sum(coalesce(e.amount, e.plan_floor)) filter (where e.st in ('active', 'past_due') and not e.paddle), 0)
  into mrr, mrr_subs, mrr_unpriced, mrr_past_due, mrr_past_due_subs,
       mrr_trialing, mrr_trialing_subs, manual_subs, manual_list
  from (
    select
      public._effective_sub_status(s.status, s.trial_ends_at) as st,
      s.paddle_subscription_id is not null as paddle,
      (select pp.display_amount from public.plan_prices pp
        where pp.paddle_price_id = s.paddle_price_id and pp.kind = 'subscription') as amount,
      (select pp.display_amount from public.plan_prices pp
        where pp.plan = s.plan and pp.kind = 'subscription' and pp.active
        order by pp.display_amount limit 1) as plan_floor
    from public.subscriptions s
    where s.user_id <> all(excl)
  ) e;

  select coalesce(sum(pp.display_amount), 0) into topup_30d
    from public.usage_topups t
    join public.plan_prices pp on pp.paddle_price_id = t.paddle_price_id
    where t.status = 'active' and t.org_id is null and t.user_id <> all(excl)
      and t.created_at > now() - interval '30 days';

  select coalesce(round(sum(ue.cost_usd), 2), 0) into cost_30d from public.usage_events ue
    where ue.user_id <> all(excl) and ue.created_at > now() - interval '30 days';
  select count(distinct ue.user_id) into active_30d from public.usage_events ue
    where ue.user_id <> all(excl) and ue.created_at > now() - interval '30 days';

  select coalesce(fmi.marketing_spend_usd, 0), coalesce(fmi.assumed_lifetime_months, 12)
    into spend, lifetime_months from public.founder_manual_inputs fmi where fmi.singleton;
  if spend is null then spend := 0; end if;
  if lifetime_months is null then lifetime_months := 12; end if;

  churn_rate := case when (paying + churned) = 0 then 0 else round(churned * 100.0 / (paying + churned), 1) end;
  arpu := case when mrr_subs = 0 then 0 else mrr / mrr_subs end;
  ltv := case
    when mrr_subs = 0 then 0
    when churn_rate > 0 then arpu / (churn_rate / 100.0)
    else arpu * lifetime_months end;

  select jsonb_build_object(
    'total_users', total_users,
    'paying_users', paying,
    'trialing_users', trialing,
    'trial_expired_users', trial_expired,
    'churned_users', churned,
    'new_paying_30d', new_paying_30d,
    'trial_to_paid_pct', case when (paying + trialing + trial_expired + churned) = 0 then 0
      else round(paying * 100.0 / (paying + trialing + trial_expired + churned), 1) end,
    'churn_rate_pct', churn_rate,
    'mrr_usd', round(mrr, 2),
    'mrr_subscriptions', mrr_subs,
    'mrr_unpriced_subscriptions', mrr_unpriced,
    'past_due_mrr_usd', round(mrr_past_due, 2),
    'past_due_subscriptions', mrr_past_due_subs,
    'trialing_mrr_usd', round(mrr_trialing, 2),
    'trialing_subscriptions', mrr_trialing_subs,
    'manual_access_subscriptions', manual_subs,
    'manual_access_list_value_usd', round(manual_list, 2),
    'topup_revenue_30d_usd', round(topup_30d, 2),
    'arr_usd', round(mrr * 12, 2),
    'arpu_usd', round(arpu, 2),
    'arpu_per_user_usd', case when total_users = 0 then 0 else round(mrr / total_users, 2) end,
    'ltv_est_usd', round(ltv, 2),
    'ltv_basis', case when churn_rate > 0 then 'churn' else 'assumption' end,
    'lifetime_months_assumption', lifetime_months,
    'cost_30d_usd', cost_30d,
    'cogs_per_active_usd', case when active_30d = 0 then 0 else round(cost_30d / active_30d, 4) end,
    'gross_margin_pct', case when mrr = 0 then 0 else round((mrr - cost_30d) * 100.0 / mrr, 1) end,
    'marketing_spend_usd', round(spend, 2),
    'cac_usd', case when new_paying_30d = 0 then null else round(spend / new_paying_30d, 2) end,
    'ltv_cac_ratio', case when new_paying_30d = 0 or spend = 0 or mrr_subs = 0 then null
      else round(ltv / (spend / new_paying_30d), 2) end,
    'generated_at', now()
  ) into result;
  return result;
end;
$$;
