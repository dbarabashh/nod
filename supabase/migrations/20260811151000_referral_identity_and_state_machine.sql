-- Paddle redelivers, retries and occasionally reorders events. Until now the
-- subscription writer applied whatever arrived last, so a late `past_due`
-- could overwrite a newer `active`. The stored event watermark makes the write
-- ordered and idempotent, which every referral decision below depends on.
alter table public.subscriptions
    add column if not exists last_paddle_event_at timestamptz,
    add column if not exists last_paddle_event_id text;

update public.subscriptions
   set last_paddle_event_at = coalesce(last_paddle_event_at, updated_at),
       last_paddle_event_id = coalesce(last_paddle_event_id, 'migration-watermark')
 where last_paddle_event_at is null or last_paddle_event_id is null;

create or replace function public.apply_paddle_subscription(
    p_user_id uuid,
    p_customer_id text,
    p_subscription_id text,
    p_price_id text,
    p_paddle_status text,
    p_period_start timestamptz,
    p_period_end timestamptz,
    p_event_id text,
    p_event_occurred_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan text;
    v_existing_plan text;
    v_existing_event_at timestamptz;
    v_existing_event_id text;
    v_status text;
begin
    if nullif(trim(p_event_id), '') is null or p_event_occurred_at is null then
        raise exception 'apply_paddle_subscription: event identity required';
    end if;

    perform pg_advisory_xact_lock(hashtext('paddle_subscription:' || p_user_id::text));

    select plan, last_paddle_event_at, last_paddle_event_id
      into v_existing_plan, v_existing_event_at, v_existing_event_id
      from public.subscriptions
     where user_id = p_user_id
     for update;
    -- Backfilled and shim-written rows carry no real event time, so they never
    -- suppress the first genuine event.
    if found
       and v_existing_event_at is not null
       and v_existing_event_id is distinct from 'migration-watermark'
       and v_existing_event_id not like 'legacy:%'
       and p_event_occurred_at <= v_existing_event_at then
        return false;
    end if;

    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    if v_plan is null then
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
        else
            return false;
        end if;
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
        converted_at, updated_at, last_paddle_event_at, last_paddle_event_id
    ) values (
        p_user_id, v_plan, v_status,
        coalesce(p_period_start, p_event_occurred_at), p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        case when v_status in ('active', 'past_due') then p_event_occurred_at end,
        now(), p_event_occurred_at, p_event_id
    )
    on conflict (user_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        current_period_start   = coalesce(p_period_start, s.current_period_start),
        current_period_end     = coalesce(p_period_end, s.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, s.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, s.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, s.paddle_price_id),
        limit_overrides        = case
                                    when s.plan is distinct from v_plan
                                    then coalesce(s.limit_overrides, '{}'::jsonb) - 'hours_per_month'
                                    else s.limit_overrides
                                 end,
        converted_at           = case
                                    when v_status in ('active', 'past_due')
                                    then coalesce(s.converted_at, p_event_occurred_at)
                                    else s.converted_at
                                 end,
        updated_at             = now(),
        last_paddle_event_at   = p_event_occurred_at,
        last_paddle_event_id   = p_event_id;
    return true;
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz, text, timestamptz) to service_role;

-- The already-deployed webhook still calls the 7-argument form. Keep it working
-- until that deploy lands, but make it defer to any row a real event has
-- already claimed so an old function can never undo an ordered write.
create or replace function public.apply_paddle_subscription(
    p_user_id uuid,
    p_customer_id text,
    p_subscription_id text,
    p_price_id text,
    p_paddle_status text,
    p_period_start timestamptz,
    p_period_end timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_last_event_at timestamptz;
    v_last_event_id text;
begin
    select last_paddle_event_at, last_paddle_event_id
      into v_last_event_at, v_last_event_id
      from public.subscriptions
     where user_id = p_user_id;
    if found
       and v_last_event_id is distinct from 'migration-watermark'
       and v_last_event_id not like 'legacy:%' then
        return;
    end if;
    perform public.apply_paddle_subscription(
        p_user_id, p_customer_id, p_subscription_id, p_price_id, p_paddle_status,
        p_period_start, p_period_end,
        'legacy:' || gen_random_uuid()::text,
        coalesce(v_last_event_at, now() - interval '1 second') + interval '1 microsecond'
    );
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;

-- Referral identity is now provider-anchored: a referral advances only against
-- immutable Paddle transaction ids, never trusted client input.
alter table public.referrals
    drop constraint if exists referrals_status_check;

alter table public.referrals
    add column if not exists attributed_at timestamptz,
    add column if not exists attribution_expires_at timestamptz,
    add column if not exists checkout_transaction_id text,
    add column if not exists checkout_bound_at timestamptz,
    add column if not exists first_payment_transaction_id text,
    add column if not exists first_payment_at timestamptz,
    add column if not exists first_payment_period_start timestamptz,
    add column if not exists paddle_subscription_id text,
    add column if not exists renewal_transaction_id text,
    add column if not exists renewal_paid_at timestamptz,
    add column if not exists renewal_period_start timestamptz,
    add column if not exists canceled_at timestamptz,
    add column if not exists cancellation_reason text,
    add column if not exists legacy_migrated_at timestamptz;

update public.referrals set status = 'attributed' where status = 'pending';

alter table public.referrals
    add constraint referrals_status_check
    check (status in ('attributed', 'activated', 'earned', 'rewarded', 'expired', 'canceled'));

update public.referrals
   set attributed_at = coalesce(attributed_at, created_at),
       attribution_expires_at = coalesce(attribution_expires_at, created_at + interval '30 days');

alter table public.referrals
    alter column attributed_at set default now(),
    alter column attributed_at set not null,
    alter column attribution_expires_at set default (now() + interval '30 days'),
    alter column attribution_expires_at set not null;

-- Rows minted by the old flow have no verifiable payment, so they cannot be
-- allowed to earn under the new rules. They keep whatever identity we can
-- recover for a manual founder review.
update public.referrals r
   set paddle_subscription_id = s.paddle_subscription_id,
       first_payment_at = coalesce(r.first_payment_at, s.converted_at, r.created_at),
       first_payment_period_start = coalesce(r.first_payment_period_start, s.current_period_start, s.converted_at, r.created_at),
       legacy_migrated_at = coalesce(r.legacy_migrated_at, now()),
       status = 'canceled',
       canceled_at = coalesce(r.canceled_at, now()),
       cancellation_reason = coalesce(r.cancellation_reason, 'legacy_attribution_unverified')
  from public.subscriptions s
 where r.referee_user_id = s.user_id
   and r.status in ('activated', 'earned')
   and r.first_payment_transaction_id is null;

update public.referrals
   set status = 'canceled',
       canceled_at = coalesce(canceled_at, now()),
       cancellation_reason = coalesce(cancellation_reason, 'legacy_attribution_unverified'),
       legacy_migrated_at = coalesce(legacy_migrated_at, now())
 where status in ('activated', 'earned')
   and first_payment_transaction_id is null;

create unique index if not exists referrals_checkout_tx_idx
    on public.referrals (checkout_transaction_id)
    where checkout_transaction_id is not null;
create unique index if not exists referrals_first_payment_tx_idx
    on public.referrals (first_payment_transaction_id)
    where first_payment_transaction_id is not null;
create unique index if not exists referrals_renewal_tx_idx
    on public.referrals (renewal_transaction_id)
    where renewal_transaction_id is not null;

create or replace function public.prevent_referral_identity_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.referrer_user_id is distinct from old.referrer_user_id
       or new.referee_user_id is distinct from old.referee_user_id
       or new.code is distinct from old.code
       or new.attributed_at is distinct from old.attributed_at
       or new.attribution_expires_at is distinct from old.attribution_expires_at
       or (old.checkout_transaction_id is not null
           and new.checkout_transaction_id is distinct from old.checkout_transaction_id)
       or (old.first_payment_transaction_id is not null
           and new.first_payment_transaction_id is distinct from old.first_payment_transaction_id)
       or (old.paddle_subscription_id is not null
           and new.paddle_subscription_id is distinct from old.paddle_subscription_id) then
        raise exception 'referral identity is immutable';
    end if;
    return new;
end;
$$;

drop trigger if exists referrals_immutable_identity on public.referrals;
create trigger referrals_immutable_identity
    before update on public.referrals
    for each row execute function public.prevent_referral_identity_change();

revoke all on function public.prevent_referral_identity_change() from public, anon, authenticated;

create table public.referral_fraud_blocks (
    user_id uuid primary key references auth.users(id) on delete cascade,
    reason text not null,
    source_referral_id uuid references public.referrals(id) on delete set null,
    created_at timestamptz not null default now()
);

alter table public.referral_fraud_blocks enable row level security;

create policy "users read own referral fraud block"
    on public.referral_fraud_blocks
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Reward liability is a ledger, not a flag on the referral: a credit is earned,
-- held, then applied by exactly one payout, and the rolling cap is countable.
create table public.reward_payouts (
    id uuid primary key default gen_random_uuid(),
    beneficiary_user_id uuid not null references auth.users(id) on delete cascade,
    paddle_subscription_id text not null,
    base_next_billed_at timestamptz not null,
    target_next_billed_at timestamptz not null,
    cap_units numeric(4,1) not null check (cap_units > 0 and cap_units <= 6),
    status text not null default 'pending'
        check (status in ('pending', 'applied', 'reconciliation_required', 'canceled')),
    idempotency_key text not null unique,
    attempts integer not null default 0,
    last_error text,
    applied_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint reward_payouts_target_after_base check (target_next_billed_at > base_next_billed_at)
);

create unique index reward_payouts_one_pending_per_user_idx
    on public.reward_payouts (beneficiary_user_id)
    where status = 'pending';

alter table public.reward_payouts enable row level security;

create policy "users read own reward payouts"
    on public.reward_payouts
    for select
    to authenticated
    using ((select auth.uid()) = beneficiary_user_id);

create table public.reward_credits (
    id uuid primary key default gen_random_uuid(),
    beneficiary_user_id uuid not null references auth.users(id) on delete cascade,
    source_type text not null check (source_type in ('referral', 'advocacy')),
    source_key text not null unique,
    referral_id uuid unique references public.referrals(id) on delete set null,
    cap_units numeric(4,1) not null check (cap_units in (0.5, 1, 3)),
    duration_months integer not null default 0 check (duration_months between 0 and 3),
    duration_days integer not null default 0 check (duration_days between 0 and 31),
    status text not null default 'pending'
        check (status in ('pending', 'payout_pending', 'applied', 'canceled', 'expired')),
    available_at timestamptz not null,
    expires_at timestamptz not null,
    payout_id uuid references public.reward_payouts(id) on delete set null,
    applied_at timestamptz,
    canceled_at timestamptz,
    cancellation_reason text,
    created_at timestamptz not null default now(),
    constraint reward_credit_duration_present check (duration_months > 0 or duration_days > 0),
    constraint reward_credit_expiry_after_availability check (expires_at > available_at)
);

create index reward_credits_due_idx
    on public.reward_credits (beneficiary_user_id, available_at)
    where status = 'pending';

alter table public.reward_credits enable row level security;

create policy "users read own reward credits"
    on public.reward_credits
    for select
    to authenticated
    using ((select auth.uid()) = beneficiary_user_id);

create table public.advocacy_reward_claims (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    activity_type text not null check (activity_type in ('review', 'social', 'story', 'blog', 'podcast', 'partnership')),
    proof_url text not null,
    disclosure_confirmed boolean not null default false,
    status text not null default 'submitted'
        check (status in ('submitted', 'approved', 'rejected', 'rewarded')),
    founder_note text,
    reviewed_at timestamptz,
    created_at timestamptz not null default now()
);

create unique index advocacy_claims_one_proof_idx
    on public.advocacy_reward_claims (user_id, activity_type, proof_url);

alter table public.advocacy_reward_claims enable row level security;

create policy "users read own advocacy claims"
    on public.advocacy_reward_claims
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Already-paid legacy rewards become applied credits so the rolling cap counts
-- what we have actually given away.
insert into public.reward_credits (
    beneficiary_user_id, source_type, source_key, referral_id, cap_units,
    duration_months, duration_days, status, available_at, expires_at, applied_at, created_at
)
select
    r.referrer_user_id, 'referral', 'referral:' || r.id::text, r.id, 1,
    1, 0, 'applied',
    coalesce(r.earned_at, r.rewarded_at, r.created_at),
    coalesce(r.earned_at, r.rewarded_at, r.created_at) + interval '12 months',
    coalesce(r.rewarded_at, r.earned_at, r.created_at),
    r.created_at
from public.referrals r
where r.status = 'rewarded'
on conflict (source_key) do nothing;

-- Legacy helpers the old webhook used. The new state machine replaces them and
-- they must not stay callable, or a stale deploy could still mutate referrals.
drop function if exists public.process_referee_payment(uuid, text, timestamptz);
drop function if exists public.claim_referral_rewards(uuid);
drop function if exists public.revert_referral_claim(text[]);

-- Checkout-time reservation. Everything the client could lie about (the code,
-- the plan, whether they ever paid) is decided here, before Paddle is called.
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

    if not exists (
        select 1 from public.plan_prices
         where paddle_price_id = p_price_id
           and plan = 'pro'
           and billing_cycle = 'monthly'
           and kind = 'subscription'
           and active
           and available_for_new_checkout
    ) then
        return jsonb_build_object('eligible', false, 'error', 'offer_not_eligible');
    end if;

    if v_code !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then
        return jsonb_build_object('eligible', false, 'error', 'invalid_referral');
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

-- Binds the reservation to the transaction that will actually be paid. If two
-- checkouts race, only the bound one can ever activate.
create or replace function public.bind_referral_checkout_transaction(
    p_referral_id uuid,
    p_referee_user_id uuid,
    p_transaction_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_bound boolean;
begin
    update public.referrals
       set checkout_transaction_id = p_transaction_id,
           checkout_bound_at = coalesce(checkout_bound_at, now())
     where id = p_referral_id
       and referee_user_id = p_referee_user_id
       and status = 'attributed'
       and attribution_expires_at > now()
       and (checkout_transaction_id is null or checkout_transaction_id = p_transaction_id)
    returning true into v_bound;
    return coalesce(v_bound, false);
end;
$$;

create or replace function public.record_billing_payer(
    p_paddle_customer_id text,
    p_user_id uuid,
    p_transaction_id text,
    p_paid_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_inserted boolean;
    v_first_transaction_id text;
    v_first_paid_at timestamptz;
begin
    if nullif(trim(p_paddle_customer_id), '') is null then
        return false;
    end if;
    insert into public.billing_payer_history (
        paddle_customer_id, last_user_id, first_paid_transaction_id, first_paid_at, updated_at
    ) values (
        p_paddle_customer_id, p_user_id, p_transaction_id, p_paid_at, now()
    )
    on conflict (paddle_customer_id) do nothing
    returning true into v_inserted;
    if coalesce(v_inserted, false) then
        return true;
    end if;

    select first_paid_transaction_id, first_paid_at
      into v_first_transaction_id, v_first_paid_at
      from public.billing_payer_history
     where paddle_customer_id = p_paddle_customer_id
     for update;
    -- A transaction delivered late but billed earlier is the real first payment.
    update public.billing_payer_history
       set last_user_id = p_user_id,
           first_paid_transaction_id = case
               when p_paid_at < first_paid_at then p_transaction_id
               else first_paid_transaction_id
           end,
           first_paid_at = least(first_paid_at, p_paid_at),
           updated_at = now()
     where paddle_customer_id = p_paddle_customer_id;
    if p_paid_at < v_first_paid_at then
        return true;
    end if;
    return v_first_transaction_id = p_transaction_id;
end;
$$;

create or replace function public.record_billing_adjustment(
    p_transaction_id text,
    p_action text,
    p_status text,
    p_is_full boolean,
    p_reason text,
    p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.billing_adjustments as a (
        paddle_transaction_id, action, status, is_full, reason, occurred_at, updated_at
    ) values (
        p_transaction_id, p_action, p_status, p_is_full, p_reason,
        coalesce(p_occurred_at, now()), now()
    )
    on conflict (paddle_transaction_id) do update set
        action = excluded.action,
        status = excluded.status,
        is_full = excluded.is_full,
        reason = excluded.reason,
        -- A refund that is later reversed leaves whatever we already revoked
        -- needing a human, so remember that it happened.
        reconciliation_required = a.reconciliation_required or (
            excluded.status in ('reversed', 'rejected')
            and (
                (a.action = 'refund' and a.status = 'approved')
                or (a.action = 'chargeback' and a.status not in ('rejected', 'reversed'))
            )
        ),
        occurred_at = excluded.occurred_at,
        updated_at = now()
    where excluded.occurred_at >= a.occurred_at;
end;
$$;

create or replace function public.cancel_referral_transaction(
    p_transaction_id text,
    p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_referral public.referrals%rowtype;
begin
    if nullif(trim(coalesce(p_transaction_id, '')), '') is null then
        return jsonb_build_object('action', 'noop');
    end if;

    select * into v_referral
      from public.referrals
     where checkout_transaction_id = p_transaction_id
        or first_payment_transaction_id = p_transaction_id
        or renewal_transaction_id = p_transaction_id
     for update;
    if not found then
        return jsonb_build_object('action', 'noop');
    end if;

    -- An applied reward is not clawed back by a later dispute; only unapplied
    -- credit is cancellable.
    update public.reward_credits
       set status = 'canceled',
           canceled_at = now(),
           cancellation_reason = p_reason
     where referral_id = v_referral.id
       and status in ('pending', 'payout_pending');

    if v_referral.status in ('rewarded', 'canceled') then
        return jsonb_build_object('action', 'credit_only', 'referral_id', v_referral.id);
    end if;

    update public.referrals
       set status = 'canceled',
           canceled_at = now(),
           cancellation_reason = p_reason
     where id = v_referral.id;
    return jsonb_build_object('action', 'canceled', 'referral_id', v_referral.id);
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
           and plan = 'pro'
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

create or replace function public.block_reward_beneficiary_for_fraud(
    p_user_id uuid,
    p_reason text,
    p_source_referral_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_canceled integer;
begin
    insert into public.referral_fraud_blocks (user_id, reason, source_referral_id)
    values (p_user_id, p_reason, p_source_referral_id)
    on conflict (user_id) do update set reason = excluded.reason;

    -- Blocking stops future and unapplied rewards. Anything already applied
    -- stays applied; reversing a granted month is a founder decision.
    update public.reward_credits
       set status = 'canceled',
           canceled_at = now(),
           cancellation_reason = coalesce(p_reason, 'fraud_block')
     where beneficiary_user_id = p_user_id
       and status in ('pending', 'payout_pending');
    get diagnostics v_canceled = row_count;

    update public.reward_payouts
       set status = 'canceled',
           last_error = coalesce(p_reason, 'fraud_block'),
           updated_at = now()
     where beneficiary_user_id = p_user_id
       and status = 'pending';

    return jsonb_build_object('blocked', true, 'canceled_credits', v_canceled);
end;
$$;

revoke all on function public.reserve_referral_attribution(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.bind_referral_checkout_transaction(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.record_billing_payer(text, uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.record_billing_adjustment(text, text, text, boolean, text, timestamptz) from public, anon, authenticated;
revoke all on function public.record_referral_transaction(uuid, text, text, timestamptz, text, text, timestamptz, boolean, boolean) from public, anon, authenticated;
revoke all on function public.cancel_referral_transaction(text, text) from public, anon, authenticated;
revoke all on function public.block_reward_beneficiary_for_fraud(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.reserve_referral_attribution(uuid, text, text, text) to service_role;
grant execute on function public.bind_referral_checkout_transaction(uuid, uuid, text) to service_role;
grant execute on function public.record_billing_payer(text, uuid, text, timestamptz) to service_role;
grant execute on function public.record_billing_adjustment(text, text, text, boolean, text, timestamptz) to service_role;
grant execute on function public.record_referral_transaction(uuid, text, text, timestamptz, text, text, timestamptz, boolean, boolean) to service_role;
grant execute on function public.cancel_referral_transaction(text, text) to service_role;
grant execute on function public.block_reward_beneficiary_for_fraud(uuid, text, uuid) to service_role;

revoke all on table public.referral_fraud_blocks from public, anon, authenticated;
revoke all on table public.reward_credits from public, anon, authenticated;
revoke all on table public.reward_payouts from public, anon, authenticated;
revoke all on table public.advocacy_reward_claims from public, anon, authenticated;
grant select on table public.referral_fraud_blocks to authenticated;
grant select on table public.reward_credits to authenticated;
grant select on table public.reward_payouts to authenticated;
grant select on table public.advocacy_reward_claims to authenticated;
grant all on table public.referral_fraud_blocks to service_role;
grant all on table public.reward_credits to service_role;
grant all on table public.reward_payouts to service_role;
grant all on table public.advocacy_reward_claims to service_role;
