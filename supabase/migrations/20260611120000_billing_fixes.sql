-- Billing fixes (code-review follow-ups):
--   • apply_paddle_subscription — fail LOUD on an unmapped price_id instead of
--     silently defaulting to 'starter' / keeping the prior plan, so a
--     misconfigured catalog (e.g. prod still on `pri_REPLACE_*`) surfaces as a
--     retried webhook rather than a mis-provisioned paying user.
--   • resolve_entitlement — expose the current `price_id` so the client can tell
--     monthly from yearly and offer a same-plan billing-cycle switch.
--   • usage_credits / apply_paddle_overage — key idempotency per line item
--     (a transaction may carry several overage packs), scale by quantity, and
--     bracket the credit to the subscription's billing period rather than the
--     calendar month so a pack lasts exactly the period it was bought for.

-- ── usage_credits: per-line-item idempotency + price id ──────────────────────
alter table public.usage_credits add column if not exists paddle_price_id text;
-- A transaction can carry several distinct overage line items; key idempotency
-- on (transaction, price) so each is credited once while event re-delivery
-- stays a no-op. (Drop the old single-column unique key.)
alter table public.usage_credits drop constraint if exists usage_credits_paddle_transaction_id_key;
create unique index if not exists usage_credits_txn_price_idx
    on public.usage_credits (paddle_transaction_id, paddle_price_id);

-- ── resolve_entitlement: add current `price_id` (rest identical to 20260610) ──
create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub          public.subscriptions%rowtype;
    v_plan         public.plans%rowtype;
    v_status       text;
    v_active       boolean;
    v_features     text[];
    v_limits       jsonb;
    v_period_start timestamptz;
    v_period_end   timestamptz;
    v_hours_used   numeric;
    v_base_hours   numeric;
    v_credit_hours numeric;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;
    if not found then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'price_id', null,
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'trial_ends_at', null, 'renewal_date', null
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
    else
        v_period_start := coalesce(v_sub.current_period_start, date_trunc('month', now()));
        v_period_end   := coalesce(v_sub.current_period_end, v_period_start + interval '1 month');
        if now() >= v_period_end then
            v_period_start := date_trunc('month', now());
            v_period_end   := v_period_start + interval '1 month';
        end if;
    end if;

    v_features := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    v_limits   := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);

    select coalesce(sum(audio_seconds), 0) / 3600.0 into v_hours_used
    from public.usage_events
    where user_id = p_user_id
      and kind = 'transcribe'
      and created_at >= v_period_start
      and created_at <  v_period_end;

    select coalesce(sum(hours), 0) into v_credit_hours
    from public.usage_credits
    where user_id = p_user_id
      and period_start <= now()
      and now() < period_end;

    v_base_hours := coalesce((v_limits->>'hours_per_month')::numeric, 0);

    return jsonb_build_object(
        'plan', v_sub.plan,
        'status', v_status,
        'price_id', v_sub.paddle_price_id,
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_hours_used, 3),
        'hours_limit', case when v_active
                            then v_base_hours + v_credit_hours
                            else 0 end,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;

-- ── apply_paddle_subscription: fail loud on an unmapped price ────────────────
create or replace function public.apply_paddle_subscription(
    p_user_id         uuid,
    p_customer_id     text,
    p_subscription_id text,
    p_price_id        text,
    p_paddle_status   text,
    p_period_start    timestamptz,
    p_period_end      timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan   text;
    v_status text;
begin
    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    -- A price we can't map must NOT silently grant a plan (the old
    -- `coalesce(..., 'starter')` mis-provisioned paying users when the catalog
    -- wasn't seeded). Raising makes the webhook 5xx so Paddle retries and the
    -- misconfiguration is visible instead of charging for the wrong tier.
    if v_plan is null then
        raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
    end if;

    v_status := case p_paddle_status
        when 'active'   then 'active'
        when 'trialing' then 'trialing'
        when 'past_due' then 'past_due'
        when 'paused'   then 'past_due'
        when 'canceled' then 'canceled'
        else 'past_due'
    end;

    insert into public.subscriptions as s (
        user_id, plan, status,
        current_period_start, current_period_end,
        paddle_customer_id, paddle_subscription_id, paddle_price_id,
        updated_at
    ) values (
        p_user_id, v_plan, v_status,
        p_period_start, p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        now()
    )
    on conflict (user_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        current_period_start   = coalesce(p_period_start, s.current_period_start),
        current_period_end     = coalesce(p_period_end, s.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, s.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, s.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, s.paddle_price_id),
        updated_at             = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;

-- ── apply_paddle_overage: per-item, quantity-aware, period-aligned ───────────
-- Signature gains p_quantity, so drop the old 3-arg version first.
drop function if exists public.apply_paddle_overage(uuid, text, text);

create or replace function public.apply_paddle_overage(
    p_user_id        uuid,
    p_transaction_id text,
    p_price_id       text,
    p_quantity       integer default 1
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hours        numeric;
    v_period_start timestamptz;
    v_period_end   timestamptz;
begin
    select overage_hours into v_hours
    from public.plan_prices
    where paddle_price_id = p_price_id and kind = 'overage';

    if v_hours is null then
        return; -- not an overage pack (e.g. the subscription's own line item)
    end if;

    -- Bracket the credit to the buyer's current billing period so an hour pack
    -- lasts exactly that period — not the calendar month, which would expire it
    -- early/late for subscriptions anchored off the 1st.
    select current_period_start, current_period_end
      into v_period_start, v_period_end
    from public.subscriptions
    where user_id = p_user_id;

    v_period_start := coalesce(v_period_start, date_trunc('month', now()));
    v_period_end   := coalesce(v_period_end, v_period_start + interval '1 month');

    insert into public.usage_credits
        (user_id, hours, period_start, period_end, paddle_transaction_id, paddle_price_id)
    values
        (p_user_id, v_hours * greatest(p_quantity, 1), v_period_start, v_period_end, p_transaction_id, p_price_id)
    on conflict (paddle_transaction_id, paddle_price_id) do nothing;
end;
$$;

revoke all on function public.apply_paddle_overage(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.apply_paddle_overage(uuid, text, text, integer) to service_role;
