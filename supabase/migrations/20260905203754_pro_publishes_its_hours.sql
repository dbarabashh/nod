-- Pro stops being sold as unlimited hours, and gets a top-up pack of its own.
--
-- NOD-138 proposes replacing Pro's "unlimited (fair use)" claim with a published
-- allowance. Measured over the 30 days to 2026-09-05, blended cost is $0.379 per
-- audio hour; with the proposal's 20% infrastructure reserve that is $0.455/h.
-- Pro yearly nets $18.96 a month after VAT and Paddle, so the allowance that
-- still clears 50% margin when a subscriber actually spends all of it is 20.8
-- hours. 20 is that number. The proposal's own 25 lands at 40%.
--
-- Nobody already subscribed moves. Two different promises have to survive, and
-- pinning the hours alone would only keep one of them:
--
--   1. The ceiling. Grandfathering runs FIRST and in the same transaction,
--      copying whatever each already-subscribed row is granted today into its
--      own `limit_overrides` — the shape `20260802100544` established, and
--      correct on any branch because it copies rather than hardcodes.
--   2. The promise that there is no ceiling. `can_start_meeting` reads
--      `plans.hours_are_unlimited`, so flipping that column alone would convert
--      every existing Pro subscriber from never-blocked into blocked-at-40. They
--      bought a plan that does not stop them, so the flag becomes per
--      subscription with the plan as its default, and every active Pro row is
--      pinned to the answer it was sold.
--
-- Price is the third promise and needs nothing: Paddle bills an existing
-- subscription against the price id it was created with, and this migration adds
-- rows rather than touching any. There is no cutover here — the $29/$288 rows
-- land inactive for the storefront and stay that way until somebody deliberately
-- runs one.
--
-- The pack. Ten hours cost us $4.55 to serve and net about $23 of a $29 sticker,
-- which makes it the healthiest line in the proposal and the reason Pro can be
-- metered at all: the subscriber who wants more buys more instead of arguing
-- about fair use. `apply_topup_purchase` already reads the hours from
-- `plan_prices`, so the single hardcoded Starter sku was the only thing standing
-- in the way — widened here rather than duplicated.
--
-- Prices are seeded as `pri_REPLACE_*` placeholders. Real Paddle ids are set per
-- branch by a one-off UPDATE, never by a migration, and the `plan_prices` policy
-- for `authenticated` is `active and available_for_new_checkout`, so a
-- placeholder is invisible to a client until the price actually exists.
--
-- This is NOD-138 under evaluation, not an approved price change. It must not
-- reach production before the proposal is approved and `docs/policies/terms.md`
-- § 7, `docs/pricing.md` and the landing page move with it.

alter table public.subscriptions
    add column if not exists hours_are_unlimited boolean;

comment on column public.subscriptions.hours_are_unlimited is
    'Per-subscription override of plans.hours_are_unlimited. Null means follow the plan. Set when a plan stops promising unlimited hours and the people who bought that promise have to keep it.';

update public.subscriptions as s
   set limit_overrides = coalesce(s.limit_overrides, '{}'::jsonb)
                         || jsonb_build_object('hours_per_month',
                                               (p.limits->>'hours_per_month')::numeric)
  from public.plans as p
 where p.plan = s.plan
   and s.status in ('active', 'past_due')
   and p.limits ? 'hours_per_month'
   -- Never clobber a ceiling someone already set by hand.
   and not (coalesce(s.limit_overrides, '{}'::jsonb) ? 'hours_per_month');

update public.subscriptions as s
   set hours_are_unlimited = true
  from public.plans as p
 where p.plan = s.plan
   and s.status in ('active', 'past_due')
   and p.hours_are_unlimited
   and s.hours_are_unlimited is null;

update public.plans
   set limits = jsonb_set(limits, '{hours_per_month}', to_jsonb(20)),
       hours_are_unlimited = false
 where plan = 'pro';

-- The resolver learns the override. Everything else is `20260811155000` verbatim:
-- re-stated in full because a Postgres function has no partial replacement.
create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub              public.subscriptions%rowtype;
    v_plan             public.plans%rowtype;
    v_status           text;
    v_active           boolean;
    v_features         text[];
    v_limits           jsonb;
    v_unlimited        boolean;
    v_term_start       timestamptz;
    v_period_start     timestamptz;
    v_period_end       timestamptz;
    v_renewal          timestamptz;
    v_months           int;
    v_consumed_seconds numeric;
    v_included_seconds numeric;
    v_top_up_seconds   numeric;
    v_remaining        numeric;
    v_billing_cycle    text;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;
    if not found then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'price_id', null,
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'hours_are_unlimited', false,
            'included_seconds', 0, 'top_up_seconds', 0,
            'consumed_seconds', 0, 'remaining_seconds', 0,
            'can_start_meeting', false,
            'billing_cycle', null,
            'trial_ends_at', null, 'renewal_date', null,
            'usage_period_start', null, 'usage_period_end', null
        );
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;

    -- The cycle the subscriber is actually on. Read here rather than in the app
    -- because a grandfathered price is hidden from the client catalogue by RLS:
    -- without this the paywall can only tell the PLAN, so it locks both cycle
    -- cards as "current" and a legitimate switch becomes impossible.
    select billing_cycle into v_billing_cycle
      from public.plan_prices where paddle_price_id = v_sub.paddle_price_id;

    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.trial_ends_at is not null
       and now() > v_sub.trial_ends_at then
        v_status := 'expired';
    end if;
    v_active := v_status in ('trialing', 'active');

    if v_status = 'trialing' then
        v_period_start := v_sub.current_period_start;
        v_period_end   := coalesce(v_sub.trial_ends_at, now() + interval '100 years');
        v_renewal      := v_period_end;
    else
        v_term_start := coalesce(v_sub.current_period_start, date_trunc('month', now()));
        v_renewal    := coalesce(v_sub.current_period_end, v_term_start + interval '1 month');
        if now() >= v_renewal then
            v_period_start := date_trunc('month', now());
            v_period_end   := v_period_start + interval '1 month';
            v_renewal      := v_period_end;
        else
            v_months := greatest(0, extract(year  from age(now(), v_term_start))::int * 12
                                  + extract(month from age(now(), v_term_start))::int);
            if now() >= v_term_start + make_interval(months => v_months + 1) then
                v_months := v_months + 1;
            end if;
            v_period_start := v_term_start + make_interval(months => v_months);
            v_period_end   := least(v_term_start + make_interval(months => v_months + 1), v_renewal);
        end if;
    end if;

    v_features  := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    v_limits    := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);
    v_unlimited := coalesce(v_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false);

    select coalesce(sum(audio_seconds), 0) into v_consumed_seconds
    from public.usage_events
    where user_id = p_user_id
      and kind = 'transcribe'
      and created_at >= v_period_start
      and created_at <  v_period_end;

    v_included_seconds := case
        when v_active then coalesce((v_limits->>'hours_per_month')::numeric, 0) * 3600
        else 0
    end;

    select coalesce(sum(hours), 0) * 3600 into v_top_up_seconds
    from public.usage_topups
    where user_id = p_user_id
      and status = 'active'
      and period_start = v_period_start
      and period_end = v_period_end
      and now() < period_end;

    if not v_active then
        v_top_up_seconds := 0;
    end if;
    v_remaining := greatest(v_included_seconds + v_top_up_seconds - v_consumed_seconds, 0);

    return jsonb_build_object(
        'plan', v_sub.plan,
        'status', v_status,
        'price_id', v_sub.paddle_price_id,
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_consumed_seconds / 3600.0, 3),
        'hours_limit', round((v_included_seconds + v_top_up_seconds) / 3600.0, 3),
        'hours_are_unlimited', v_unlimited,
        'included_seconds', round(v_included_seconds),
        'top_up_seconds', round(v_top_up_seconds),
        'consumed_seconds', round(v_consumed_seconds),
        'remaining_seconds', round(v_remaining),
        'can_start_meeting', v_active and (v_unlimited or v_remaining > 0),
        'billing_cycle', v_billing_cycle,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon;
grant execute on function public.resolve_entitlement(uuid) to authenticated, service_role;

-- Any top-up sku, not the one Starter was launched with. The plan a pack belongs
-- to is read off its own catalogue row, so adding the next one is an insert.
alter table public.topup_checkout_intents
    drop constraint if exists topup_checkout_intents_sku_check;

alter table public.topup_checkout_intents
    add constraint topup_checkout_intents_sku_check
    check (sku in ('starter_5h_usd_12', 'pro_10h_usd_29'));

create or replace function public.create_topup_checkout_intent(
    p_user_id uuid,
    p_sku text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_entitlement jsonb;
    v_price_id text;
    v_plan text;
    v_subscription_id text;
    v_intent_id uuid;
    v_expires_at timestamptz;
begin
    if p_user_id is null then
        raise exception 'create_topup_checkout_intent requires a user';
    end if;

    -- An unknown sku and a sku whose Paddle price has not been created yet are
    -- the same answer to the caller: there is nothing here to buy.
    select paddle_price_id, plan into v_price_id, v_plan
      from public.plan_prices
     where sku = p_sku
       and billing_cycle = 'one_time'
       and kind = 'topup'
       and active
       and available_for_new_checkout;
    if v_price_id is null or v_price_id like 'pri_REPLACE_%' then
        return jsonb_build_object('created', false, 'error', 'topup_unconfigured');
    end if;

    v_entitlement := public.resolve_entitlement(p_user_id);
    if v_entitlement->>'plan' <> v_plan or v_entitlement->>'status' <> 'active' then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    select paddle_subscription_id into v_subscription_id
      from public.subscriptions
     where user_id = p_user_id
       and plan = v_plan
       and status = 'active';
    if v_subscription_id is null then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    -- Short-lived on purpose: an intent that outlives its billing period would
    -- credit hours to a month the customer never paid for.
    v_expires_at := least(now() + interval '1 hour', (v_entitlement->>'usage_period_end')::timestamptz);
    if v_expires_at <= now() then
        return jsonb_build_object('created', false, 'error', 'no_active_usage_period');
    end if;

    insert into public.topup_checkout_intents (
        user_id, paddle_subscription_id, paddle_price_id, sku,
        period_start, period_end, included_seconds, expires_at
    ) values (
        p_user_id, v_subscription_id, v_price_id, p_sku,
        (v_entitlement->>'usage_period_start')::timestamptz,
        (v_entitlement->>'usage_period_end')::timestamptz,
        coalesce((v_entitlement->>'included_seconds')::numeric, 0),
        v_expires_at
    ) returning id into v_intent_id;

    return jsonb_build_object(
        'created', true,
        'intent_id', v_intent_id,
        'paddle_price_id', v_price_id,
        'expires_at', v_expires_at
    );
end;
$$;

revoke all on function public.create_topup_checkout_intent(uuid, text) from public, anon, authenticated;
grant execute on function public.create_topup_checkout_intent(uuid, text) to service_role;

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, available_for_new_checkout
) values
    ('pri_REPLACE_pro_topup_10h_29', 'pro', 'one_time', 'topup', 29, 'USD', false, 21, true, 'pro_10h_usd_29', 10, false),
    ('pri_REPLACE_pro_monthly_29',   'pro', 'monthly', 'subscription', 29, 'USD', false, 15, true, 'pro_monthly_usd_29', null, false),
    ('pri_REPLACE_pro_yearly_288',   'pro', 'yearly',  'subscription', 24, 'USD', false, 16, true, 'pro_yearly_usd_288', null, false)
on conflict (paddle_price_id) do nothing;
