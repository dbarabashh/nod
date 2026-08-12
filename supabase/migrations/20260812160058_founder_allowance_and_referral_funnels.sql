-- Ported verbatim from `nod-founder-dashboard/db/founder_dashboard_rpcs.sql`,
-- where both funnels were written and then never applied: the dashboard called
-- them for days and got 404 from PostgREST. Schema belongs in migrations, so
-- this file is now the source of truth for the two.

-- Starter allowance gate and the top-up it sells (NOD-76).
--
-- The gate counts come from `product_events`, so they only exist once a release
-- that emits them is out; `first_event_at` is null until then, and the page says
-- "waiting for a release" instead of showing an honest-looking zero funnel. The
-- purchase side comes from `usage_topups`, which is provider truth rather than
-- client telemetry, and `schema_ready` is false until the pricing migrations are
-- applied — a missing table must read as "not deployed", never as an error.
create or replace function public.founder_allowance_funnel(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  excl uuid[] := public._excluded_user_ids();
  since timestamptz := now() - make_interval(days => greatest(coalesce(p_days, 30), 1));
  schema_ready boolean := to_regclass('public.usage_topups') is not null;
  gate_views bigint := 0;
  gate_users bigint := 0;
  topup_clicks bigint := 0;
  upgrade_clicks bigint := 0;
  dismissals bigint := 0;
  failures bigint := 0;
  checkouts bigint := 0;
  purchases bigint := 0;
  first_event timestamptz;
  hours_bought numeric := 0;
  revenue numeric := 0;
  review_required bigint := 0;
  refunded bigint := 0;
  packs_active bigint := 0;
  starter_active bigint := 0;
begin
  perform public._assert_founder();

  select
    count(*) filter (where pe.event = 'allowance_gate_viewed'),
    count(distinct pe.user_id) filter (where pe.event = 'allowance_gate_viewed'),
    count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'success'),
    count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'granted'),
    count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'cancelled'),
    count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'failure'),
    count(*) filter (where pe.event = 'topup_checkout_started'),
    count(*) filter (where pe.event = 'topup_purchased'),
    min(pe.occurred_at)
  into gate_views, gate_users, topup_clicks, upgrade_clicks, dismissals, failures,
       checkouts, purchases, first_event
  from product_events pe
  where pe.occurred_at >= since
    and pe.user_id <> all(excl)
    and pe.event in (
      'allowance_gate_viewed', 'allowance_gate_action',
      'topup_checkout_started', 'topup_purchased'
    );

  select count(*) into starter_active
  from subscriptions s
  where s.plan = 'starter' and s.status = 'active' and s.user_id <> all(excl);

  if schema_ready then
    select
      coalesce(sum(t.hours) filter (where t.status = 'active'), 0),
      coalesce(sum(coalesce(pp.display_amount, 0)) filter (where t.status = 'active'), 0),
      count(*) filter (where t.status = 'review_required'),
      count(*) filter (where t.status = 'refunded'),
      count(*) filter (where t.status = 'active' and now() < t.period_end)
    into hours_bought, revenue, review_required, refunded, packs_active
    from usage_topups t
    left join plan_prices pp on pp.paddle_price_id = t.paddle_price_id
    where t.created_at >= since and t.user_id <> all(excl);
  end if;

  return jsonb_build_object(
    'window_days', greatest(coalesce(p_days, 30), 1),
    'schema_ready', schema_ready,
    'first_event_at', first_event,
    'starter_active', starter_active,
    'gate_views', gate_views,
    'gate_users', gate_users,
    'topup_clicks', topup_clicks,
    'upgrade_clicks', upgrade_clicks,
    'dismissals', dismissals,
    'failures', failures,
    'checkouts_started', checkouts,
    'purchases', purchases,
    'packs_active', packs_active,
    'hours_bought', hours_bought,
    'revenue_usd', round(revenue, 2),
    'review_required', review_required,
    'refunded', refunded
  );
end;
$$;

revoke all on function public.founder_allowance_funnel(integer) from public, anon;
grant execute on function public.founder_allowance_funnel(integer) to authenticated;

-- Referral state and the reward liability behind it (NOD-76).
--
-- Every number here is database state, not telemetry, so it is meaningful the
-- moment the schema is deployed. `outstanding_cap_units` is what we currently owe
-- in free-month equivalents: credits earned or claimed but not yet applied.
create or replace function public.founder_referral_funnel()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  excl uuid[] := public._excluded_user_ids();
  schema_ready boolean := to_regclass('public.reward_credits') is not null;
  codes bigint := 0;
  attributed bigint := 0;
  activated bigint := 0;
  earned bigint := 0;
  rewarded bigint := 0;
  expired bigint := 0;
  canceled bigint := 0;
  credits_pending bigint := 0;
  credits_payout_pending bigint := 0;
  credits_applied bigint := 0;
  credits_expired bigint := 0;
  credits_canceled bigint := 0;
  outstanding numeric := 0;
  payouts_pending bigint := 0;
  payouts_applied bigint := 0;
  payouts_stuck bigint := 0;
  fraud_blocks bigint := 0;
begin
  perform public._assert_founder();

  select count(*) into codes
  from referral_codes rc where rc.user_id <> all(excl);

  if not schema_ready then
    return jsonb_build_object('schema_ready', false, 'codes_minted', codes);
  end if;

  select
    count(*) filter (where r.status = 'attributed'),
    count(*) filter (where r.status = 'activated'),
    count(*) filter (where r.status = 'earned'),
    count(*) filter (where r.status = 'rewarded'),
    count(*) filter (where r.status = 'expired'),
    count(*) filter (where r.status = 'canceled')
  into attributed, activated, earned, rewarded, expired, canceled
  from referrals r
  where r.referrer_user_id <> all(excl) and r.referee_user_id <> all(excl);

  select
    count(*) filter (where c.status = 'pending'),
    count(*) filter (where c.status = 'payout_pending'),
    count(*) filter (where c.status = 'applied'),
    count(*) filter (where c.status = 'expired'),
    count(*) filter (where c.status = 'canceled'),
    coalesce(sum(c.cap_units) filter (where c.status in ('pending', 'payout_pending')), 0)
  into credits_pending, credits_payout_pending, credits_applied, credits_expired,
       credits_canceled, outstanding
  from reward_credits c
  where c.beneficiary_user_id <> all(excl);

  select
    count(*) filter (where p.status = 'pending'),
    count(*) filter (where p.status = 'applied'),
    count(*) filter (where p.status = 'reconciliation_required')
  into payouts_pending, payouts_applied, payouts_stuck
  from reward_payouts p
  where p.beneficiary_user_id <> all(excl);

  select count(*) into fraud_blocks
  from referral_fraud_blocks b where b.user_id <> all(excl);

  return jsonb_build_object(
    'schema_ready', true,
    'codes_minted', codes,
    'attributed', attributed,
    'activated', activated,
    'earned', earned,
    'rewarded', rewarded,
    'expired', expired,
    'canceled', canceled,
    'credits_pending', credits_pending,
    'credits_payout_pending', credits_payout_pending,
    'credits_applied', credits_applied,
    'credits_expired', credits_expired,
    'credits_canceled', credits_canceled,
    'outstanding_cap_units', outstanding,
    'payouts_pending', payouts_pending,
    'payouts_applied', payouts_applied,
    'payouts_stuck', payouts_stuck,
    'fraud_blocks', fraud_blocks
  );
end;
$$;

revoke all on function public.founder_referral_funnel() from public, anon;
grant execute on function public.founder_referral_funnel() to authenticated;
