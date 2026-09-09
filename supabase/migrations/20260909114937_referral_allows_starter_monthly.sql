-- The referral offer was promised as "50% off the first month of Starter or Pro"
-- everywhere a person can read it, but both referral functions only accepted
-- the Pro monthly price. Starter monthly joins; the code format is now checked
-- before the plan so a non-referral string is reported as invalid, not as an
-- ineligible plan.

create or replace function public.reserve_referral_attribution(
    p_referee_user_id uuid,
    p_code text,
    p_price_id text,
    p_paddle_customer_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_code text := upper(trim(p_code));
    v_referrer uuid;
    v_existing public.referrals%rowtype;
    v_converted_at timestamptz;
    v_referral_id uuid;
begin
    perform pg_advisory_xact_lock(hashtext('referral_attribution:' || p_referee_user_id::text));

    if v_code !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then
        return jsonb_build_object('eligible', false, 'error', 'invalid_referral');
    end if;

    if not exists (
        select 1 from public.plan_prices
         where paddle_price_id = p_price_id
           and plan in ('starter', 'pro')
           and billing_cycle = 'monthly'
           and kind = 'subscription'
           and active
           and available_for_new_checkout
    ) then
        return jsonb_build_object('eligible', false, 'error', 'offer_not_eligible');
    end if;

    if nullif(trim(p_paddle_customer_id), '') is null then
        return jsonb_build_object('eligible', false, 'error', 'offer_not_eligible');
    end if;

    select user_id into v_referrer from public.referral_codes where code = v_code;
    if v_referrer is null then
        return jsonb_build_object('eligible', false, 'error', 'invalid_referral');
    end if;
    if v_referrer = p_referee_user_id then
        return jsonb_build_object('eligible', false, 'error', 'self_referral');
    end if;
    if exists (select 1 from public.referral_fraud_blocks where user_id = v_referrer) then
        return jsonb_build_object('eligible', false, 'error', 'invalid_referral');
    end if;

    select converted_at into v_converted_at
      from public.subscriptions where user_id = p_referee_user_id;
    if v_converted_at is not null then
        return jsonb_build_object('eligible', false, 'error', 'already_paid');
    end if;
    -- The same Paddle customer paying under a fresh account is still not a
    -- first-ever payer.
    if exists (
        select 1 from public.billing_payer_history
         where paddle_customer_id = p_paddle_customer_id
    ) then
        return jsonb_build_object('eligible', false, 'error', 'already_paid');
    end if;

    select * into v_existing from public.referrals where referee_user_id = p_referee_user_id;
    if found then
        if v_existing.code = v_code
           and v_existing.status = 'attributed'
           and v_existing.attribution_expires_at > now() then
            return jsonb_build_object('eligible', true, 'referral_id', v_existing.id, 'code', v_code);
        end if;
        return jsonb_build_object('eligible', false, 'error', 'already_redeemed');
    end if;

    insert into public.referrals (
        referrer_user_id, referee_user_id, code, status, attributed_at, attribution_expires_at
    ) values (
        v_referrer, p_referee_user_id, v_code, 'attributed', now(), now() + interval '30 days'
    ) returning id into v_referral_id;

    return jsonb_build_object('eligible', true, 'referral_id', v_referral_id, 'code', v_code);
end;
$$;

-- The whole referral lifecycle, driven only by completed Paddle transactions.
create or replace function public.record_referral_transaction(
    p_referee_user_id uuid,
    p_transaction_id text,
    p_price_id text,
    p_occurred_at timestamptz,
    p_origin text,
    p_subscription_id text,
    p_billing_period_start timestamptz,
    p_referral_discount_applied boolean,
    p_is_first_payer_transaction boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_referral public.referrals%rowtype;
    v_credit_id uuid;
begin
    select * into v_referral
      from public.referrals
     where referee_user_id = p_referee_user_id
     for update;
    if not found or v_referral.status in ('canceled', 'expired', 'rewarded') then
        return jsonb_build_object('action', 'noop');
    end if;

    -- An earlier full-price payment arriving late means this account was never a
    -- first-ever payer, so the activation it already got is void.
    if v_referral.status in ('activated', 'earned')
       and coalesce(p_is_first_payer_transaction, false)
       and v_referral.first_payment_transaction_id is distinct from p_transaction_id then
        perform public.cancel_referral_transaction(
            v_referral.first_payment_transaction_id,
            'earlier_first_payment_detected'
        );
        return jsonb_build_object('action', 'canceled_not_first_payment');
    end if;

    if exists (
        select 1 from public.billing_adjustments a
         where a.paddle_transaction_id = p_transaction_id
           and (
               (a.action = 'refund' and a.status = 'approved')
               or (a.action = 'chargeback' and a.status not in ('rejected', 'reversed'))
           )
    ) then
        update public.referrals
           set status = 'canceled',
               canceled_at = now(),
               cancellation_reason = 'adjustment_before_transaction_completion'
         where id = v_referral.id;
        return jsonb_build_object('action', 'adjusted');
    end if;

    if not exists (
        select 1 from public.plan_prices
         where paddle_price_id = p_price_id
           and plan in ('starter', 'pro')
           and billing_cycle = 'monthly'
           and kind = 'subscription'
    ) then
        return jsonb_build_object('action', 'offer_not_eligible');
    end if;

    if v_referral.status = 'attributed' then
        if not coalesce(p_is_first_payer_transaction, false) then
            update public.referrals
               set status = 'canceled',
                   canceled_at = now(),
                   cancellation_reason = 'not_first_payer_transaction'
             where id = v_referral.id;
            return jsonb_build_object('action', 'already_paid');
        end if;
        if v_referral.checkout_transaction_id is null
           or v_referral.checkout_transaction_id <> p_transaction_id
           or not coalesce(p_referral_discount_applied, false) then
            return jsonb_build_object('action', 'unbound_checkout');
        end if;
        if p_origin not in ('api', 'web') then
            return jsonb_build_object('action', 'invalid_initial_origin');
        end if;
        if nullif(trim(coalesce(p_subscription_id, '')), '') is null then
            return jsonb_build_object('action', 'invalid_subscription');
        end if;
        if p_occurred_at > v_referral.attribution_expires_at then
            update public.referrals set status = 'expired' where id = v_referral.id;
            return jsonb_build_object('action', 'expired');
        end if;

        update public.referrals
           set status = 'activated',
               first_payment_transaction_id = p_transaction_id,
               first_payment_at = p_occurred_at,
               paddle_subscription_id = p_subscription_id,
               first_payment_period_start = coalesce(p_billing_period_start, p_occurred_at)
         where id = v_referral.id;
        return jsonb_build_object('action', 'activated', 'referral_id', v_referral.id,
                                  'referrer_user_id', v_referral.referrer_user_id);
    end if;

    -- Earning requires a genuine renewal: same subscription, a later billing
    -- period, and far enough from the first payment that a mid-cycle change
    -- cannot masquerade as one.
    if v_referral.status = 'activated'
       and v_referral.first_payment_transaction_id is distinct from p_transaction_id
       and p_origin = 'subscription_recurring'
       and p_subscription_id = v_referral.paddle_subscription_id
       and p_billing_period_start is not null
       and p_billing_period_start > coalesce(v_referral.first_payment_period_start, v_referral.first_payment_at)
       and p_occurred_at >= coalesce(v_referral.first_payment_at, v_referral.created_at) + interval '20 days' then
        if exists (select 1 from public.referral_fraud_blocks where user_id = v_referral.referrer_user_id) then
            update public.referrals
               set status = 'canceled',
                   canceled_at = now(),
                   cancellation_reason = 'referrer_fraud_blocked'
             where id = v_referral.id;
            return jsonb_build_object('action', 'blocked');
        end if;

        update public.referrals
           set status = 'earned',
               earned_at = p_occurred_at,
               renewal_transaction_id = p_transaction_id,
               renewal_paid_at = p_occurred_at,
               renewal_period_start = p_billing_period_start
         where id = v_referral.id;

        insert into public.reward_credits (
            beneficiary_user_id, source_type, source_key, referral_id, cap_units,
            duration_months, duration_days, status, available_at, expires_at
        ) values (
            v_referral.referrer_user_id, 'referral', 'referral:' || v_referral.id::text,
            v_referral.id, 1, 1, 0, 'pending',
            p_occurred_at + interval '7 days',
            p_occurred_at + interval '12 months'
        )
        on conflict (source_key) do nothing
        returning id into v_credit_id;

        return jsonb_build_object(
            'action', 'earned',
            'referral_id', v_referral.id,
            'referrer_user_id', v_referral.referrer_user_id,
            'reward_credit_id', v_credit_id,
            'available_at', p_occurred_at + interval '7 days'
        );
    end if;

    return jsonb_build_object('action', 'noop');
end;
$$;
