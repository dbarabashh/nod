-- Four defects two independent reviews found in this branch's own work.
--
-- 1. IDOR. `20260905203754` and `20260905205944` granted
--    `resolve_entitlement(uuid)` to `authenticated`. Every migration before them
--    granted it to `service_role` alone, on purpose: it is SECURITY DEFINER,
--    takes an arbitrary user id and checks nothing, which is why the
--    `auth.uid()`-pinned `get_entitlement()` wrapper exists and is what the app
--    actually calls. With the grant, any signed-in account could read anybody
--    else's plan, price, hours, renewal date — and, since this branch, their
--    organization and its seat count and pooled usage. Revoked. `join_live_room`
--    keeps working because a SECURITY DEFINER function calls it as its owner.
--
-- 2. The Pro hour pack charged and granted nothing. `20260905203754` widened
--    `create_topup_checkout_intent` and claimed the Starter sku was "the only
--    thing standing in the way". There were two: `apply_topup_purchase` also
--    hardcoded `v_subscription.plan <> 'starter'`, so every `pro_10h_usd_29`
--    purchase landed `review_required` and credited zero hours against a real
--    $29 charge. The plan a pack belongs to now comes from its catalogue row,
--    which is where the rest of the function already reads the hours from.
--
-- 3. A failed workspace card took capacity away from people paying for their
--    own. `20260905205944` let `past_due` into the organization branch, so a
--    member holding a live personal Pro subscription resolved against an
--    organization that had stopped paying and came back with no features and no
--    hours. An organization that is not paying no longer answers for anybody;
--    its members fall back to whatever they hold themselves.
--
-- 4. The organization branch destroyed two things the member had bought. A
--    grandfathered subscriber's "never blocked" promise is pinned on their own
--    subscription and was being ignored the moment a workspace covered them, and
--    an hour pack bought for the period in flight was dropped on the floor
--    (`v_top_up_seconds := 0`). Both are the member's property, not the
--    workspace's, so both now survive being covered: the promise ORs, and the
--    pack is credited against whichever period is resolved.
--
-- Still open after this migration, and deliberately not fixed here because each
-- needs a product decision rather than a patch: pooled consumption is attributed
-- to *current* seat holders, so removing a member returns their spent hours to
-- the pool; a role change or a seat reduction made in Paddle's own portal can
-- silently uncover an active member; and an organization has no `trial_ends_at`,
-- so a trial whose terminating event is missed never expires.

revoke execute on function public.resolve_entitlement(uuid) from authenticated;

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
    v_pack_plan text;
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

    -- The plan comes from the pack's own row, beside the hours it grants. A pack
    -- is only ever valid for the plan it was listed under.
    select top_up_hours, plan into v_hours, v_pack_plan
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
       or v_subscription.plan is distinct from v_pack_plan
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

revoke all on function public.apply_topup_purchase(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_topup_purchase(uuid, text, text, uuid) to service_role;

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
        -- The workspace's answer, or the member's own if they were sold a
        -- promise the workspace does not make. What somebody already bought is
        -- not the employer's to withdraw.
        --
        -- Coalesced because a member with no personal subscription at all reads
        -- NULL here, and a NULL would propagate into `can_start_meeting`.
        v_unlimited := coalesce(v_org_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false)
                       or coalesce(v_sub.status in ('trialing', 'active', 'past_due')
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
    end if;

    -- Hours somebody bought are theirs whoever is paying for the plan, so this
    -- is asked the same way in both branches — against whichever period was
    -- resolved, which is the period the pack was pinned to when it was bought.
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
