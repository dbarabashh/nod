-- Immutable provider facts the referral and top-up flows both read. They live
-- here because `apply_topup_purchase` below already needs the adjustment log.
create table public.billing_payer_history (
    paddle_customer_id text primary key,
    last_user_id uuid references auth.users(id) on delete set null,
    first_paid_transaction_id text unique,
    first_paid_at timestamptz not null,
    updated_at timestamptz not null default now()
);

alter table public.billing_payer_history enable row level security;

create table public.billing_adjustments (
    paddle_transaction_id text primary key,
    action text not null,
    status text not null,
    is_full boolean not null,
    reason text,
    reconciliation_required boolean not null default false,
    occurred_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.billing_adjustments enable row level security;

revoke all on table public.billing_payer_history from public, anon, authenticated;
revoke all on table public.billing_adjustments from public, anon, authenticated;
grant all on table public.billing_payer_history to service_role;
grant all on table public.billing_adjustments to service_role;

-- The metering window logic is unchanged from `20260730081521` (anniversary
-- month inside a multi-month term). What is new: the answer is reported in
-- seconds, purchased top-ups add to the allowance for their own period only,
-- and `can_start_meeting` is the single fact the start gate reads.
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
    v_term_start       timestamptz;
    v_period_start     timestamptz;
    v_period_end       timestamptz;
    v_renewal          timestamptz;
    v_months           int;
    v_consumed_seconds numeric;
    v_included_seconds numeric;
    v_top_up_seconds   numeric;
    v_remaining        numeric;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;
    if not found then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'price_id', null,
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'included_seconds', 0, 'top_up_seconds', 0,
            'consumed_seconds', 0, 'remaining_seconds', 0,
            'can_start_meeting', false,
            'trial_ends_at', null, 'renewal_date', null,
            'usage_period_start', null, 'usage_period_end', null
        );
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;

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

    v_features := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    v_limits   := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);

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
        'included_seconds', round(v_included_seconds),
        'top_up_seconds', round(v_top_up_seconds),
        'consumed_seconds', round(v_consumed_seconds),
        'remaining_seconds', round(v_remaining),
        'can_start_meeting', v_active
            and (coalesce(v_plan.hours_are_unlimited, false) or v_remaining > 0),
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;

-- Leases are short-lived and renewed by use. A client that crashed, was force
-- quit, or lost the network at End cannot hold recording hostage: its lease
-- goes stale in 90 seconds of silence and the next start takes it over.
create or replace function public.start_meeting_lease(
    p_user_id uuid,
    p_meeting_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_ttl constant interval := interval '15 minutes';
    v_stale constant interval := interval '90 seconds';
    v_existing public.meeting_start_leases%rowtype;
    v_entitlement jsonb;
    v_expires_at timestamptz;
begin
    perform pg_advisory_xact_lock(hashtext('meeting_start:' || p_user_id::text));

    update public.meeting_start_leases
       set status = 'ended',
           ended_at = coalesce(ended_at, expires_at)
     where user_id = p_user_id
       and status = 'active'
       and expires_at <= now();

    -- A lease nobody is feeding chunks to is abandoned, not active.
    update public.meeting_start_leases
       set status = 'ended',
           ended_at = coalesce(ended_at, now())
     where user_id = p_user_id
       and status = 'active'
       and meeting_id <> p_meeting_id
       and coalesce(last_used_at, granted_at) < now() - v_stale;

    select * into v_existing
      from public.meeting_start_leases
     where meeting_id = p_meeting_id
     for update;
    if found then
        if v_existing.user_id <> p_user_id then
            return jsonb_build_object('granted', false, 'error', 'meeting_conflict');
        end if;
        if v_existing.status = 'ended' then
            return jsonb_build_object('granted', false, 'error', 'meeting_lease_ended');
        end if;
        if v_existing.expires_at > now() then
            -- Same meeting asking again (retry, restart of the start request).
            v_expires_at := now() + v_ttl;
            update public.meeting_start_leases
               set expires_at = v_expires_at,
                   last_used_at = now()
             where meeting_id = p_meeting_id;
            return jsonb_build_object(
                'granted', true,
                'meeting_id', p_meeting_id,
                'expires_at', v_expires_at
            );
        end if;
    end if;

    if exists (
        select 1
          from public.meeting_start_leases
         where user_id = p_user_id
           and status = 'active'
           and meeting_id <> p_meeting_id
           and expires_at > now()
    ) then
        return jsonb_build_object('granted', false, 'error', 'meeting_already_active');
    end if;

    v_entitlement := public.resolve_entitlement(p_user_id);
    if not coalesce((v_entitlement->>'can_start_meeting')::boolean, false) then
        return jsonb_build_object(
            'granted', false,
            'error', 'meeting_limit_reached',
            'entitlement', v_entitlement
        );
    end if;

    v_expires_at := now() + v_ttl;
    insert into public.meeting_start_leases (meeting_id, user_id, expires_at, last_used_at)
    values (p_meeting_id, p_user_id, v_expires_at, now())
    on conflict (meeting_id) do update set
        status = 'active',
        granted_at = now(),
        expires_at = v_expires_at,
        ended_at = null,
        last_used_at = now();

    return jsonb_build_object(
        'granted', true,
        'meeting_id', p_meeting_id,
        'expires_at', v_expires_at
    );
end;
$$;

-- Called on every transcription chunk, so it writes at most once a minute: a
-- long meeting costs one row update per minute, not one per chunk.
create or replace function public.validate_meeting_lease(
    p_user_id uuid,
    p_meeting_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_ttl constant interval := interval '15 minutes';
    v_expires_at timestamptz;
    v_touched_at timestamptz;
begin
    select expires_at, coalesce(last_used_at, granted_at)
      into v_expires_at, v_touched_at
      from public.meeting_start_leases
     where meeting_id = p_meeting_id
       and user_id = p_user_id
       and status = 'active';
    if not found or v_expires_at <= now() then
        return false;
    end if;

    if v_touched_at < now() - interval '60 seconds'
       or v_expires_at < now() + interval '10 minutes' then
        update public.meeting_start_leases
           set last_used_at = now(),
               expires_at = greatest(expires_at, now() + v_ttl)
         where meeting_id = p_meeting_id;
    end if;
    return true;
end;
$$;

create or replace function public.end_meeting_lease(
    p_user_id uuid,
    p_meeting_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_ended boolean;
begin
    update public.meeting_start_leases
       set status = 'ended',
           ended_at = coalesce(ended_at, now())
     where meeting_id = p_meeting_id
       and user_id = p_user_id
       and status = 'active'
    returning true into v_ended;
    if coalesce(v_ended, false) then
        return true;
    end if;
    return exists (
        select 1 from public.meeting_start_leases
         where meeting_id = p_meeting_id and user_id = p_user_id
    );
end;
$$;

revoke all on function public.start_meeting_lease(uuid, uuid) from public, anon, authenticated;
revoke all on function public.validate_meeting_lease(uuid, uuid) from public, anon, authenticated;
revoke all on function public.end_meeting_lease(uuid, uuid) from public, anon, authenticated;
grant execute on function public.start_meeting_lease(uuid, uuid) to service_role;
grant execute on function public.validate_meeting_lease(uuid, uuid) to service_role;
grant execute on function public.end_meeting_lease(uuid, uuid) to service_role;

-- Flips chunk-level enforcement on, and only together with a minimum build that
-- speaks the protocol. Monotonic: a typo or a retry can never lower the gate.
create or replace function public.activate_meeting_lease_enforcement(p_compatible_build integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_minimum_build integer;
    v_lease_build integer;
begin
    if p_compatible_build <= 0 then
        return jsonb_build_object('activated', false, 'error', 'invalid_build');
    end if;
    select minimum_build, meeting_lease_required_build
      into v_minimum_build, v_lease_build
      from public.app_config
     where platform = 'macos'
     for update;
    if not found then
        return jsonb_build_object('activated', false, 'error', 'config_missing');
    end if;
    if p_compatible_build < v_minimum_build
       or (v_lease_build <> 2147483647 and p_compatible_build < v_lease_build) then
        return jsonb_build_object('activated', false, 'error', 'build_downgrade');
    end if;
    update public.app_config
       set minimum_build = p_compatible_build,
           meeting_lease_required_build = p_compatible_build,
           updated_at = now()
     where platform = 'macos';
    return jsonb_build_object('activated', true, 'build', p_compatible_build);
end;
$$;

revoke all on function public.activate_meeting_lease_enforcement(integer) from public, anon, authenticated;
grant execute on function public.activate_meeting_lease_enforcement(integer) to service_role;

-- The one path that can expose the replacement catalog. Real ids are per-branch
-- data, so they arrive as arguments; placeholders can never reach Paddle.
create or replace function public.cutover_pricing_catalog(
    p_starter_monthly_price_id text,
    p_starter_yearly_price_id text,
    p_pro_monthly_price_id text,
    p_pro_yearly_price_id text,
    p_starter_topup_price_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_ids text[] := array[
        p_starter_monthly_price_id,
        p_starter_yearly_price_id,
        p_pro_monthly_price_id,
        p_pro_yearly_price_id,
        p_starter_topup_price_id
    ];
    v_expected record;
begin
    if exists (
        select 1 from unnest(v_ids) id
         where id is null or id !~ '^pri_[a-z0-9]{26}$'
    ) or (select count(distinct id) from unnest(v_ids) id) <> 5 then
        return jsonb_build_object('cutover', false, 'error', 'invalid_price_ids');
    end if;

    perform pg_advisory_xact_lock(hashtext('pricing_catalog_cutover'));
    lock table public.plan_prices in share row exclusive mode;

    -- A supplied id that already exists as something else (a legacy price, or a
    -- copy/paste of the wrong cycle) must not be silently repurposed.
    for v_expected in
        select * from (values
            (p_starter_monthly_price_id, 'starter_monthly_usd_15', 'starter', 'monthly', 'subscription'),
            (p_starter_yearly_price_id, 'starter_yearly_usd_144', 'starter', 'yearly', 'subscription'),
            (p_pro_monthly_price_id, 'pro_monthly_usd_24', 'pro', 'monthly', 'subscription'),
            (p_pro_yearly_price_id, 'pro_yearly_usd_240', 'pro', 'yearly', 'subscription'),
            (p_starter_topup_price_id, 'starter_5h_usd_12', 'starter', 'one_time', 'topup')
        ) as expected(price_id, sku, plan, billing_cycle, kind)
    loop
        if exists (
            select 1 from public.plan_prices p
             where p.paddle_price_id = v_expected.price_id
               and (p.sku is distinct from v_expected.sku
                    or p.plan is distinct from v_expected.plan
                    or p.billing_cycle is distinct from v_expected.billing_cycle
                    or p.kind is distinct from v_expected.kind)
        ) then
            return jsonb_build_object('cutover', false, 'error', 'price_id_conflict');
        end if;
    end loop;

    update public.plan_prices
       set sku = null
     where paddle_price_id like 'pri_REPLACE_%';

    insert into public.plan_prices (
        paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
        is_founding, sort_order, active, sku, top_up_hours, available_for_new_checkout
    ) values
        (p_starter_monthly_price_id, 'starter', 'monthly', 'subscription', 15, 'USD', false, 11, true, 'starter_monthly_usd_15', null, true),
        (p_starter_yearly_price_id, 'starter', 'yearly', 'subscription', 12, 'USD', false, 12, true, 'starter_yearly_usd_144', null, true),
        (p_pro_monthly_price_id, 'pro', 'monthly', 'subscription', 24, 'USD', false, 13, true, 'pro_monthly_usd_24', null, true),
        (p_pro_yearly_price_id, 'pro', 'yearly', 'subscription', 20, 'USD', false, 14, true, 'pro_yearly_usd_240', null, true),
        (p_starter_topup_price_id, 'starter', 'one_time', 'topup', 12, 'USD', false, 20, true, 'starter_5h_usd_12', 5, true)
    on conflict (paddle_price_id) do update set
        plan = excluded.plan,
        billing_cycle = excluded.billing_cycle,
        kind = excluded.kind,
        display_amount = excluded.display_amount,
        currency = excluded.currency,
        sort_order = excluded.sort_order,
        active = true,
        sku = excluded.sku,
        top_up_hours = excluded.top_up_hours,
        available_for_new_checkout = true;

    -- Superseded prices stay active and resolvable so renewals of existing
    -- subscriptions keep mapping to a plan; they just leave the storefront.
    update public.plan_prices
       set available_for_new_checkout = false
     where paddle_price_id <> all(v_ids);

    return jsonb_build_object('cutover', true, 'price_ids', to_jsonb(v_ids));
end;
$$;

revoke all on function public.cutover_pricing_catalog(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.cutover_pricing_catalog(text, text, text, text, text) to service_role;

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
    v_subscription_id text;
    v_intent_id uuid;
    v_expires_at timestamptz;
begin
    if p_sku <> 'starter_5h_usd_12' then
        return jsonb_build_object('created', false, 'error', 'invalid_topup_sku');
    end if;

    select paddle_price_id into v_price_id
      from public.plan_prices
     where sku = p_sku
       and plan = 'starter'
       and billing_cycle = 'one_time'
       and kind = 'topup'
       and active
       and available_for_new_checkout;
    if v_price_id is null or v_price_id like 'pri_REPLACE_%' then
        return jsonb_build_object('created', false, 'error', 'topup_unconfigured');
    end if;

    v_entitlement := public.resolve_entitlement(p_user_id);
    if v_entitlement->>'plan' <> 'starter' or v_entitlement->>'status' <> 'active' then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    select paddle_subscription_id into v_subscription_id
      from public.subscriptions
     where user_id = p_user_id
       and plan = 'starter'
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

create or replace function public.attach_topup_checkout_transaction(
    p_intent_id uuid,
    p_transaction_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_attached boolean;
begin
    update public.topup_checkout_intents
       set paddle_transaction_id = p_transaction_id,
           status = 'checkout_created',
           updated_at = now()
     where id = p_intent_id
       and (
           (status = 'created' and paddle_transaction_id is null)
           or (status = 'checkout_created' and paddle_transaction_id = p_transaction_id)
       )
    returning true into v_attached;
    return coalesce(v_attached, false);
end;
$$;

create or replace function public.cancel_topup_checkout_intent(
    p_intent_id uuid,
    p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.topup_checkout_intents
       set status = 'canceled',
           reconciliation_reason = p_reason,
           updated_at = now()
     where id = p_intent_id
       and status = 'created';
end;
$$;

-- Fulfilment never guesses. If anything moved between checkout and payment
-- (plan change, new billing period, refund landing first), the purchase is
-- recorded for review instead of silently granting or vanishing.
create or replace function public.apply_topup_purchase(
    p_user_id uuid,
    p_transaction_id text,
    p_price_id text,
    p_intent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_intent public.topup_checkout_intents%rowtype;
    v_hours numeric;
    v_entitlement jsonb;
    v_subscription public.subscriptions%rowtype;
    v_topup_id uuid;
    v_reason text;
begin
    select * into v_intent
      from public.topup_checkout_intents
     where id = p_intent_id
     for update;
    if not found
       or v_intent.user_id <> p_user_id
       or v_intent.paddle_price_id <> p_price_id then
        return jsonb_build_object('applied', false, 'error', 'invalid_topup_intent');
    end if;
    if v_intent.paddle_transaction_id is not null
       and v_intent.paddle_transaction_id <> p_transaction_id then
        return jsonb_build_object('applied', false, 'error', 'topup_transaction_mismatch');
    end if;

    select id into v_topup_id
      from public.usage_topups
     where paddle_transaction_id = p_transaction_id;
    if v_topup_id is not null then
        return jsonb_build_object('applied', false, 'reason', 'already_applied', 'topup_id', v_topup_id);
    end if;

    select top_up_hours into v_hours
      from public.plan_prices
     where paddle_price_id = p_price_id
       and sku = v_intent.sku
       and kind = 'topup'
       and active;
    if v_hours is null then
        return jsonb_build_object('applied', false, 'error', 'invalid_topup_sku');
    end if;

    select * into v_subscription from public.subscriptions where user_id = p_user_id;
    v_entitlement := public.resolve_entitlement(p_user_id);

    if exists (
        select 1 from public.billing_adjustments a
         where a.paddle_transaction_id = p_transaction_id
           and (
               (a.action = 'refund' and a.status = 'approved')
               or (a.action = 'chargeback' and a.status not in ('rejected', 'reversed'))
           )
    ) then
        v_reason := 'transaction_adjusted_before_fulfilment';
    elsif v_intent.status = 'canceled' then
        v_reason := 'checkout_intent_canceled';
    elsif v_intent.expires_at <= now() then
        v_reason := 'checkout_intent_expired';
    elsif v_subscription.user_id is null
       or v_subscription.plan <> 'starter'
       or v_subscription.status <> 'active'
       or v_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id then
        v_reason := 'subscription_changed_before_payment';
    elsif (v_entitlement->>'usage_period_start')::timestamptz is distinct from v_intent.period_start
       or (v_entitlement->>'usage_period_end')::timestamptz is distinct from v_intent.period_end then
        v_reason := 'billing_period_changed_before_payment';
    end if;

    insert into public.usage_topups (
        user_id, paddle_transaction_id, paddle_price_id, hours, included_seconds,
        period_start, period_end, status, refund_reason
    ) values (
        p_user_id, p_transaction_id, p_price_id, v_hours, v_intent.included_seconds,
        v_intent.period_start, v_intent.period_end,
        case when v_reason is null then 'active' else 'review_required' end,
        v_reason
    )
    on conflict (paddle_transaction_id) do nothing
    returning id into v_topup_id;

    if v_topup_id is null then
        select id into v_topup_id
          from public.usage_topups
         where paddle_transaction_id = p_transaction_id;
        return jsonb_build_object('applied', false, 'reason', 'already_applied', 'topup_id', v_topup_id);
    end if;

    update public.topup_checkout_intents
       set paddle_transaction_id = p_transaction_id,
           status = case when v_reason is null then 'fulfilled' else 'reconciliation_required' end,
           reconciliation_reason = v_reason,
           updated_at = now()
     where id = v_intent.id;

    if v_reason is not null then
        return jsonb_build_object(
            'applied', false,
            'error', 'topup_reconciliation_required',
            'reason', v_reason,
            'topup_id', v_topup_id
        );
    end if;
    return jsonb_build_object('applied', true, 'topup_id', v_topup_id, 'hours', v_hours);
end;
$$;

-- A refunded pack loses only what is still unused. Time already spent is a
-- founder decision, not an automatic clawback, and the balance never goes
-- negative.
create or replace function public.refund_topup_transaction(
    p_transaction_id text,
    p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_topup public.usage_topups%rowtype;
    v_consumed numeric;
    v_prior numeric;
    v_consumed_from_topup numeric;
begin
    select * into v_topup
      from public.usage_topups
     where paddle_transaction_id = p_transaction_id
     for update;
    if not found then
        return jsonb_build_object('action', 'noop');
    end if;
    if v_topup.status <> 'active' then
        return jsonb_build_object('action', v_topup.status);
    end if;

    select coalesce(sum(u.audio_seconds), 0) into v_consumed
      from public.usage_events u
     where u.user_id = v_topup.user_id
       and u.kind = 'transcribe'
       and u.created_at >= v_topup.period_start
       and u.created_at < v_topup.period_end;

    -- Packs are consumed in purchase order, so an earlier pack absorbs overage
    -- before this one does.
    select coalesce(sum(t.hours), 0) * 3600 into v_prior
      from public.usage_topups t
     where t.user_id = v_topup.user_id
       and t.status = 'active'
       and t.period_start = v_topup.period_start
       and t.period_end = v_topup.period_end
       and (t.created_at, t.id) < (v_topup.created_at, v_topup.id);

    v_consumed_from_topup := greatest(
        least(v_consumed - v_topup.included_seconds - v_prior, v_topup.hours * 3600),
        0
    );

    if v_consumed_from_topup > 0 then
        update public.usage_topups
           set status = 'review_required',
               refund_reason = p_reason
         where id = v_topup.id;
        return jsonb_build_object('action', 'review_required', 'consumed_seconds', v_consumed_from_topup);
    end if;

    update public.usage_topups
       set status = 'refunded',
           refunded_at = now(),
           refund_reason = p_reason
     where id = v_topup.id;
    return jsonb_build_object('action', 'refunded');
end;
$$;

create or replace function public.review_topup_adjustment(
    p_transaction_id text,
    p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_updated boolean;
begin
    update public.usage_topups
       set status = 'review_required',
           refund_reason = p_reason
     where paddle_transaction_id = p_transaction_id
       and status = 'active'
    returning true into v_updated;
    return jsonb_build_object('action', case when coalesce(v_updated, false) then 'review_required' else 'noop' end);
end;
$$;

revoke all on function public.create_topup_checkout_intent(uuid, text) from public, anon, authenticated;
revoke all on function public.attach_topup_checkout_transaction(uuid, text) from public, anon, authenticated;
revoke all on function public.cancel_topup_checkout_intent(uuid, text) from public, anon, authenticated;
revoke all on function public.apply_topup_purchase(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.refund_topup_transaction(text, text) from public, anon, authenticated;
revoke all on function public.review_topup_adjustment(text, text) from public, anon, authenticated;
grant execute on function public.create_topup_checkout_intent(uuid, text) to service_role;
grant execute on function public.attach_topup_checkout_transaction(uuid, text) to service_role;
grant execute on function public.cancel_topup_checkout_intent(uuid, text) to service_role;
grant execute on function public.apply_topup_purchase(uuid, text, text, uuid) to service_role;
grant execute on function public.refund_topup_transaction(text, text) to service_role;
grant execute on function public.review_topup_adjustment(text, text) to service_role;
