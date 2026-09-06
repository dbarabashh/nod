-- A workspace pack is checked against the workspace's period, not the buyer's.
--
-- `apply_topup_purchase` pinned a workspace intent to the workspace's Paddle
-- subscription and period, then — at fulfilment — asked the *buyer's* resolver
-- whether the period still matched. The buyer is a person: switch their active
-- organization between checkout and Paddle's `transaction.completed`, or cut
-- the seats so they fall outside coverage, and their resolver answers for a
-- different payer while the workspace's window has not moved at all. Paddle
-- took the money and the pack was parked for review. The workspace's own
-- window is what was pinned, so it is what is compared.
--
-- `create_topup_checkout_intent` also returns the plan the pack belongs to, so
-- the checkout's funnel event can say which plan bought it instead of the
-- `starter` it has said for every pack since there was one pack.

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
    v_org_id uuid;
    v_role text;
    v_subscription_id text;
    v_intent_id uuid;
    v_expires_at timestamptz;
begin
    if p_user_id is null then
        raise exception 'create_topup_checkout_intent requires a user';
    end if;

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

    if v_entitlement->>'payer' = 'organization' then
        v_org_id := (v_entitlement->>'org_id')::uuid;
        select m.role into v_role
          from public.org_members m
         where m.org_id = v_org_id
           and m.user_id = p_user_id
           and m.status = 'active';
        if v_role is null or v_role not in ('owner', 'admin') then
            return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
        end if;
        select paddle_subscription_id into v_subscription_id
          from public.org_subscriptions
         where org_id = v_org_id
           and plan = v_plan
           and status = 'active';
    else
        select paddle_subscription_id into v_subscription_id
          from public.subscriptions
         where user_id = p_user_id
           and plan = v_plan
           and status = 'active';
    end if;
    if v_subscription_id is null then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    v_expires_at := least(now() + interval '1 hour', (v_entitlement->>'usage_period_end')::timestamptz);
    if v_expires_at <= now() then
        return jsonb_build_object('created', false, 'error', 'no_active_usage_period');
    end if;

    insert into public.topup_checkout_intents (
        user_id, org_id, paddle_subscription_id, paddle_price_id, sku,
        period_start, period_end, included_seconds, expires_at
    ) values (
        p_user_id, v_org_id, v_subscription_id, v_price_id, p_sku,
        (v_entitlement->>'usage_period_start')::timestamptz,
        (v_entitlement->>'usage_period_end')::timestamptz,
        coalesce((v_entitlement->>'included_seconds')::numeric, 0),
        v_expires_at
    ) returning id into v_intent_id;

    return jsonb_build_object(
        'created', true,
        'intent_id', v_intent_id,
        'org_id', v_org_id,
        'plan', v_plan,
        'paddle_price_id', v_price_id,
        'expires_at', v_expires_at
    );
end;
$$;

revoke all on function public.create_topup_checkout_intent(uuid, text) from public, anon, authenticated;
grant execute on function public.create_topup_checkout_intent(uuid, text) to service_role;

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
    v_credits numeric;
    v_pack_plan text;
    v_entitlement jsonb;
    v_subscription public.subscriptions%rowtype;
    v_org_subscription public.org_subscriptions%rowtype;
    v_window record;
    v_period_start timestamptz;
    v_period_end timestamptz;
    v_subscription_changed boolean;
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

    select top_up_hours, top_up_credits, plan into v_hours, v_credits, v_pack_plan
      from public.plan_prices
     where paddle_price_id = p_price_id
       and sku = v_intent.sku
       and kind = 'topup'
       and active;
    if v_hours is null and v_credits is null then
        return jsonb_build_object('applied', false, 'error', 'invalid_topup_sku');
    end if;

    -- The subscription the intent was pinned to has to still be the one being
    -- paid for, and its period the one the intent named. For a workspace that
    -- is the workspace's subscription and the workspace's window — whoever
    -- pressed the button, and whatever has happened to them since.
    if v_intent.org_id is not null then
        select * into v_org_subscription from public.org_subscriptions where org_id = v_intent.org_id;
        v_subscription_changed := v_org_subscription.org_id is null
            or v_org_subscription.plan is distinct from v_pack_plan
            or v_org_subscription.status <> 'active'
            or v_org_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id;
        if not v_subscription_changed then
            select * into v_window from public.monthly_usage_window(
                v_org_subscription.status, v_org_subscription.current_period_end,
                v_org_subscription.current_period_start, v_org_subscription.current_period_end);
            v_period_start := v_window.period_start;
            v_period_end   := v_window.period_end;
        end if;
    else
        select * into v_subscription from public.subscriptions where user_id = p_user_id;
        v_subscription_changed := v_subscription.user_id is null
            or v_subscription.plan is distinct from v_pack_plan
            or v_subscription.status <> 'active'
            or v_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id;
        v_entitlement := public.resolve_entitlement(p_user_id);
        v_period_start := (v_entitlement->>'usage_period_start')::timestamptz;
        v_period_end   := (v_entitlement->>'usage_period_end')::timestamptz;
    end if;

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
    elsif v_subscription_changed then
        v_reason := 'subscription_changed_before_payment';
    elsif v_period_start is distinct from v_intent.period_start
       or v_period_end is distinct from v_intent.period_end then
        v_reason := 'billing_period_changed_before_payment';
    end if;

    insert into public.usage_topups (
        user_id, org_id, paddle_transaction_id, paddle_price_id, hours, credits, included_seconds,
        period_start, period_end, status, refund_reason
    ) values (
        p_user_id, v_intent.org_id, p_transaction_id, p_price_id, v_hours, v_credits, v_intent.included_seconds,
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
    return jsonb_build_object('applied', true, 'topup_id', v_topup_id, 'hours', v_hours, 'credits', v_credits);
end;
$$;

revoke all on function public.apply_topup_purchase(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_topup_purchase(uuid, text, text, uuid) to service_role;
