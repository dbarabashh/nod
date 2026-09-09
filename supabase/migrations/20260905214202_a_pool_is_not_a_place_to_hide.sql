-- Two more, both found by re-reviewing this branch's own fixes.
--
-- 1. The hour-pack rescue in `20260905212849` was a no-op. Moving the top-up
--    query out of the personal branch was not enough: it matches a pack on the
--    exact period it was pinned to, and a pack can only ever be minted on the
--    personal path, so its period is a personal subscription's window and never
--    equals the organization's. The pack was still lost, and the migration's own
--    comment said otherwise. The organization branch now credits a pack whose
--    pinned period overlaps the workspace period and has not run out. Those hours
--    were bought by the person drawing on the pool, so they go where their
--    consumption goes.
--
-- 2. A lapsed personal card could remove an organization's metering. The same
--    migration ORed the member's grandfathered "never blocked" pin into the
--    workspace branch while accepting `past_due` as evidence of it — so somebody
--    whose own card had failed twenty days ago recorded without limit against
--    their employer's pooled allowance, and letting the card lapse was strictly
--    better than cancelling. It contradicted the rule that migration had just
--    established for organizations: something that is not being paid for does not
--    confer anything. The promise is now honoured only while the subscription
--    carrying it is live.

create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub              public.subscriptions%rowtype;
    v_org_sub          public.org_subscriptions%rowtype;
    v_org_id           uuid;
    v_plan             public.plans%rowtype;
    v_payer            text;
    v_seats            int;
    v_status           text;
    v_active           boolean;
    v_features         text[];
    v_limits           jsonb;
    v_unlimited        boolean;
    v_window           record;
    v_period_start     timestamptz;
    v_period_end       timestamptz;
    v_renewal          timestamptz;
    v_consumed_seconds numeric;
    v_included_seconds numeric;
    v_top_up_seconds   numeric;
    v_remaining        numeric;
    v_billing_cycle    text;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;

    select p.active_org_id into v_org_id
      from public.profiles p where p.user_id = p_user_id;
    if v_org_id is not null then
        select * into v_org_sub from public.org_subscriptions where org_id = v_org_id;
        if not found then
            v_org_sub := null;
        -- `past_due` is deliberately not here. A workspace that has stopped
        -- paying must not answer for a member who pays for themselves.
        elsif v_org_sub.status not in ('trialing', 'active') then
            v_org_sub := null;
        elsif not public.org_seat_is_held(v_org_id, p_user_id) then
            v_org_sub := null;
        end if;
    end if;

    if v_org_sub.org_id is null and v_sub.user_id is null then
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
            'payer', 'none', 'org_id', null, 'seats', null,
            'trial_ends_at', null, 'renewal_date', null,
            'usage_period_start', null, 'usage_period_end', null
        );
    end if;

    if v_org_sub.org_id is not null then
        v_payer  := 'organization';
        v_seats  := v_org_sub.seats;
        v_status := v_org_sub.status;
        select * into v_plan from public.plans where plan = v_org_sub.plan;
        select billing_cycle into v_billing_cycle
          from public.plan_prices where paddle_price_id = v_org_sub.paddle_price_id;
        select * into v_window from public.monthly_usage_window(
            v_status, null, v_org_sub.current_period_start, v_org_sub.current_period_end);
        v_limits    := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_org_sub.limit_overrides, '{}'::jsonb);
        -- The workspace's answer, or the member's own if they were sold a promise
        -- the workspace does not make — but only while the subscription carrying
        -- that promise is itself being paid for. A `past_due` card confers
        -- nothing, on either side.
        v_unlimited := coalesce(v_org_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false)
                       or coalesce(v_sub.status in ('trialing', 'active')
                                   and coalesce(v_sub.hours_are_unlimited, false), false);
        -- A grant on the person is additive and survives the organization paying.
        v_features  := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    else
        v_payer  := 'personal';
        v_status := v_sub.status;
        if v_status = 'trialing'
           and v_sub.trial_ends_at is not null
           and now() > v_sub.trial_ends_at then
            v_status := 'expired';
        end if;
        select * into v_plan from public.plans where plan = v_sub.plan;
        -- Read here rather than in the app because a grandfathered price is
        -- hidden from the client catalogue by RLS: without this the paywall can
        -- only tell the PLAN, so it locks both cycle cards as "current" and a
        -- legitimate switch becomes impossible.
        select billing_cycle into v_billing_cycle
          from public.plan_prices where paddle_price_id = v_sub.paddle_price_id;
        select * into v_window from public.monthly_usage_window(
            v_status, v_sub.trial_ends_at, v_sub.current_period_start, v_sub.current_period_end);
        v_limits    := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);
        v_unlimited := coalesce(v_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false);
        v_features  := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    end if;

    v_period_start := v_window.period_start;
    v_period_end   := v_window.period_end;
    v_renewal      := v_window.renewal;
    v_active       := v_status in ('trialing', 'active');

    if v_payer = 'organization' then
        select coalesce(sum(u.audio_seconds), 0) into v_consumed_seconds
        from public.usage_events u
        join public.org_seat_holders(v_org_id) h on h.user_id = u.user_id
        where u.kind = 'transcribe'
          and u.created_at >= v_period_start
          and u.created_at <  v_period_end;
        v_included_seconds := case
            when v_active then coalesce((v_limits->>'hours_per_month')::numeric, 0) * 3600 * v_seats
            else 0
        end;
        -- A pack is always minted on the personal path, so its pinned window is a
        -- personal subscription's and never equals the workspace's. Overlap is
        -- the only test that can find it.
        select coalesce(sum(hours), 0) * 3600 into v_top_up_seconds
        from public.usage_topups
        where user_id = p_user_id
          and status = 'active'
          and period_start < v_period_end
          and period_end   > v_period_start
          and now() < period_end;
    else
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
    end if;
    if not v_active then
        v_top_up_seconds := 0;
    end if;

    v_remaining := greatest(v_included_seconds + v_top_up_seconds - v_consumed_seconds, 0);

    return jsonb_build_object(
        'plan', case when v_payer = 'organization'
                     then v_org_sub.plan else coalesce(v_sub.plan, 'none') end,
        'status', v_status,
        'price_id', case when v_payer = 'organization'
                         then v_org_sub.paddle_price_id else v_sub.paddle_price_id end,
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
        'payer', v_payer,
        'org_id', case when v_payer = 'organization' then v_org_id end,
        'seats', v_seats,
        'trial_ends_at', case when v_payer = 'organization' then null else v_sub.trial_ends_at end,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;
