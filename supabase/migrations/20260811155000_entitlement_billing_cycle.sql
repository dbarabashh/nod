-- Tell the client which billing cycle the subscription is on.
--
-- After a catalogue cutover a grandfathered subscriber's price row is no longer
-- visible to the app (RLS hides anything not `available_for_new_checkout`), so the
-- paywall knew the plan but not the cycle — and locked BOTH cycle cards of that
-- plan as "current plan", removing the monthly/yearly switch for exactly the
-- people most likely to want it. The resolver is SECURITY DEFINER, so it can read
-- the superseded row and answer the question directly.

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
        'billing_cycle', v_billing_cycle,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;
