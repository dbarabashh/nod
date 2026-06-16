-- Remove the overage hour-pack feature. It was scaffolded but never shipped:
-- no client "buy a pack" UI, no Paddle overage products, and the x-nod-overage
-- flag is ignored. Rather than carry dead infrastructure (and promise something
-- in pricing that doesn't work), strip it. The monthly hours stay a soft
-- allowance enforced as before — they just can't be topped up. Re-introduce
-- (usage_credits + apply_paddle_overage + resolver fold-in) when the purchase
-- flow actually ships.

delete from public.plan_prices where kind = 'overage';
drop function if exists public.apply_paddle_overage(uuid, text, text, integer);
drop table if exists public.usage_credits;
alter table public.plan_prices drop column if exists overage_hours;

-- Resolver without the overage-credit fold-in: hours_limit is just the plan's
-- monthly allowance. Otherwise identical to 20260611120000 (keeps `price_id`).
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
                            then coalesce((v_limits->>'hours_per_month')::numeric, 0)
                            else 0 end,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;
