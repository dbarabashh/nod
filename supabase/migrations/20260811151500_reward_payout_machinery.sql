-- Paying a reward means pushing the beneficiary's next renewal out. That is one
-- Paddle write against an observed billing date, so the claim records the exact
-- date it expects to see and the reconcile step compares what Paddle actually
-- reports. An ambiguous outcome is never guessed twice.

create or replace function public.claim_reward_payout(
    p_beneficiary_user_id uuid,
    p_base_next_billed_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_existing public.reward_payouts%rowtype;
    v_subscription_id text;
    v_used_units numeric;
    v_remaining_units numeric;
    v_credit record;
    v_claimed uuid[] := '{}';
    v_months integer := 0;
    v_days integer := 0;
    v_units numeric := 0;
    v_payout_id uuid;
    v_target timestamptz;
begin
    perform pg_advisory_xact_lock(hashtext('reward_payout:' || p_beneficiary_user_id::text));

    -- One in-flight payout per user: a second Paddle write while the first is
    -- unresolved is how a beneficiary gets two free months for one credit.
    select * into v_existing
      from public.reward_payouts
     where beneficiary_user_id = p_beneficiary_user_id
       and status in ('pending', 'reconciliation_required')
     order by created_at
     limit 1
     for update;
    if found then
        return jsonb_build_object(
            'count', (select count(*) from public.reward_credits where payout_id = v_existing.id),
            'payout_id', v_existing.id,
            'status', v_existing.status,
            'paddle_subscription_id', v_existing.paddle_subscription_id,
            'base_next_billed_at', v_existing.base_next_billed_at,
            'target_next_billed_at', v_existing.target_next_billed_at
        );
    end if;

    if exists (select 1 from public.referral_fraud_blocks where user_id = p_beneficiary_user_id) then
        return jsonb_build_object('count', 0, 'error', 'fraud_blocked');
    end if;

    select paddle_subscription_id into v_subscription_id
      from public.subscriptions
     where user_id = p_beneficiary_user_id
       and status = 'active';
    if v_subscription_id is null or p_base_next_billed_at is null then
        return jsonb_build_object('count', 0, 'error', 'not_payable');
    end if;

    -- Rolling 12-month cap counts everything already granted, referral and
    -- advocacy together.
    select coalesce(sum(cap_units), 0) into v_used_units
      from public.reward_credits
     where beneficiary_user_id = p_beneficiary_user_id
       and status in ('applied', 'payout_pending')
       and coalesce(applied_at, created_at) > now() - interval '12 months';
    v_remaining_units := 6 - v_used_units;
    if v_remaining_units <= 0 then
        return jsonb_build_object('count', 0, 'error', 'cap_reached');
    end if;

    v_target := p_base_next_billed_at;
    for v_credit in
        select id, cap_units, duration_months, duration_days
          from public.reward_credits
         where beneficiary_user_id = p_beneficiary_user_id
           and status = 'pending'
           and available_at <= now()
           and expires_at > now()
         order by available_at, id
         for update
    loop
        exit when v_credit.cap_units > v_remaining_units;
        v_remaining_units := v_remaining_units - v_credit.cap_units;
        v_units := v_units + v_credit.cap_units;
        v_months := v_months + v_credit.duration_months;
        v_days := v_days + v_credit.duration_days;
        v_claimed := v_claimed || v_credit.id;
    end loop;

    if array_length(v_claimed, 1) is null then
        return jsonb_build_object('count', 0);
    end if;

    -- Calendar-safe: month-end dates must not overflow into the next month.
    v_target := (p_base_next_billed_at + make_interval(months => v_months) + make_interval(days => v_days));

    insert into public.reward_payouts (
        beneficiary_user_id, paddle_subscription_id, base_next_billed_at,
        target_next_billed_at, cap_units, idempotency_key
    ) values (
        p_beneficiary_user_id, v_subscription_id, p_base_next_billed_at,
        v_target, v_units,
        'payout:' || p_beneficiary_user_id::text || ':' || md5(array_to_string(v_claimed, ','))
    )
    on conflict (idempotency_key) do nothing
    returning id into v_payout_id;
    if v_payout_id is null then
        select id into v_payout_id
          from public.reward_payouts
         where idempotency_key = 'payout:' || p_beneficiary_user_id::text || ':' || md5(array_to_string(v_claimed, ','));
        return jsonb_build_object('count', 0, 'payout_id', v_payout_id, 'error', 'already_claimed');
    end if;

    update public.reward_credits
       set status = 'payout_pending',
           payout_id = v_payout_id
     where id = any(v_claimed);

    return jsonb_build_object(
        'count', array_length(v_claimed, 1),
        'payout_id', v_payout_id,
        'status', 'pending',
        'paddle_subscription_id', v_subscription_id,
        'base_next_billed_at', p_base_next_billed_at,
        'target_next_billed_at', v_target
    );
end;
$$;

-- Resolves a claim against what Paddle now reports. Target reached → applied.
-- Still at base → releasable, so a later run retries. Anything else → a human.
create or replace function public.reconcile_reward_payout(
    p_payout_id uuid,
    p_observed_next_billed_at timestamptz,
    p_error text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_payout public.reward_payouts%rowtype;
begin
    select * into v_payout
      from public.reward_payouts
     where id = p_payout_id
     for update;
    if not found then
        return jsonb_build_object('action', 'noop');
    end if;
    if v_payout.status = 'applied' then
        return jsonb_build_object('action', 'applied');
    end if;

    if p_observed_next_billed_at = v_payout.target_next_billed_at then
        update public.reward_payouts
           set status = 'applied',
               applied_at = coalesce(applied_at, now()),
               attempts = attempts + 1,
               last_error = null,
               updated_at = now()
         where id = p_payout_id;
        update public.reward_credits
           set status = 'applied',
               applied_at = now()
         where payout_id = p_payout_id
           and status = 'payout_pending';
        return jsonb_build_object('action', 'applied');
    end if;

    if p_observed_next_billed_at = v_payout.base_next_billed_at then
        -- Nothing moved at the provider, so the credits go back in the queue
        -- rather than sitting claimed-but-unpaid.
        update public.reward_credits
           set status = case when status = 'payout_pending' then 'pending' else status end,
               payout_id = null
         where payout_id = p_payout_id;
        update public.reward_payouts
           set status = 'canceled',
               attempts = attempts + 1,
               last_error = coalesce(p_error, 'provider_unchanged'),
               updated_at = now()
         where id = p_payout_id;
        return jsonb_build_object('action', 'canceled');
    end if;

    update public.reward_payouts
       set status = 'reconciliation_required',
           attempts = attempts + 1,
           last_error = coalesce(p_error, 'observed_billing_date_unexpected'),
           updated_at = now()
     where id = p_payout_id;
    return jsonb_build_object('action', 'reconciliation_required');
end;
$$;

create or replace function public.expire_reward_credits()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_expired integer;
begin
    update public.reward_credits
       set status = 'expired'
     where status = 'pending'
       and expires_at <= now();
    get diagnostics v_expired = row_count;

    -- An expired credit leaves its referral in a state that claims a reward is
    -- still coming, which is the version a founder would read in the dashboard.
    update public.referrals r
       set status = 'canceled',
           canceled_at = coalesce(r.canceled_at, now()),
           cancellation_reason = coalesce(r.cancellation_reason, 'reward_credit_expired')
      from public.reward_credits c
     where c.referral_id = r.id
       and c.status = 'expired'
       and r.status = 'earned';
    return v_expired;
end;
$$;

create or replace function public.reward_payout_candidates(p_limit integer default 25)
returns table (beneficiary_user_id uuid, due_credits bigint)
language sql
stable
security definer
set search_path = ''
as $$
    select credit.beneficiary_user_id, count(*) as due_credits
      from public.reward_credits credit
      join public.subscriptions subscription
        on subscription.user_id = credit.beneficiary_user_id
       and subscription.status = 'active'
       and subscription.paddle_subscription_id is not null
     where credit.status = 'pending'
       and credit.available_at <= now()
       and credit.expires_at > now()
       and not exists (
           select 1 from public.referral_fraud_blocks block
            where block.user_id = credit.beneficiary_user_id
       )
     group by credit.beneficiary_user_id
     union
    -- An unresolved payout is a candidate too: reconciliation is what closes it.
    select payout.beneficiary_user_id, 0
      from public.reward_payouts payout
     where payout.status in ('pending', 'reconciliation_required')
     limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

-- Founder-approved advocacy shares the same ledger and the same rolling cap as
-- referrals, so a story and a referral can never together exceed six months.
create or replace function public.grant_advocacy_reward(
    p_user_id uuid,
    p_activity_type text,
    p_proof_url text,
    p_disclosure_confirmed boolean,
    p_founder_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_claim_id uuid;
    v_cap_units numeric;
    v_months integer := 0;
    v_days integer := 0;
    v_credit_id uuid;
begin
    if p_activity_type not in ('review', 'social', 'story', 'blog', 'podcast', 'partnership') then
        return jsonb_build_object('granted', false, 'error', 'invalid_activity');
    end if;
    if not coalesce(p_disclosure_confirmed, false) then
        return jsonb_build_object('granted', false, 'error', 'disclosure_required');
    end if;
    if exists (select 1 from public.referral_fraud_blocks where user_id = p_user_id) then
        return jsonb_build_object('granted', false, 'error', 'fraud_blocked');
    end if;

    if p_activity_type in ('review', 'social') then
        v_cap_units := 0.5; v_days := 14;
    elsif p_activity_type in ('story', 'blog') then
        v_cap_units := 1; v_months := 1;
    else
        v_cap_units := 3; v_months := 3;
    end if;

    insert into public.advocacy_reward_claims (
        user_id, activity_type, proof_url, disclosure_confirmed, status, founder_note, reviewed_at
    ) values (
        p_user_id, p_activity_type, p_proof_url, true, 'approved', p_founder_note, now()
    )
    on conflict (user_id, activity_type, proof_url) do update set
        status = 'approved',
        founder_note = coalesce(excluded.founder_note, public.advocacy_reward_claims.founder_note),
        reviewed_at = now()
    returning id into v_claim_id;

    insert into public.reward_credits (
        beneficiary_user_id, source_type, source_key, cap_units,
        duration_months, duration_days, status, available_at, expires_at
    ) values (
        p_user_id, 'advocacy', 'advocacy:' || v_claim_id::text, v_cap_units,
        v_months, v_days, 'pending', now(), now() + interval '12 months'
    )
    on conflict (source_key) do nothing
    returning id into v_credit_id;

    if v_credit_id is null then
        return jsonb_build_object('granted', false, 'error', 'already_granted', 'claim_id', v_claim_id);
    end if;

    update public.advocacy_reward_claims set status = 'rewarded' where id = v_claim_id;
    return jsonb_build_object('granted', true, 'claim_id', v_claim_id, 'reward_credit_id', v_credit_id);
end;
$$;

-- Keeps the referral row honest about its credit without duplicating state.
create or replace function public.sync_referral_reward_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.source_type = 'referral' and new.referral_id is not null and new.status = 'applied' then
        update public.referrals
           set status = 'rewarded',
               rewarded_at = coalesce(rewarded_at, now())
         where id = new.referral_id
           and status in ('earned', 'activated');
    end if;
    return new;
end;
$$;

drop trigger if exists sync_referral_reward_status on public.reward_credits;
create trigger sync_referral_reward_status
    after update of status on public.reward_credits
    for each row execute function public.sync_referral_reward_status();

revoke all on function public.claim_reward_payout(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.reconcile_reward_payout(uuid, timestamptz, text) from public, anon, authenticated;
revoke all on function public.expire_reward_credits() from public, anon, authenticated;
revoke all on function public.reward_payout_candidates(integer) from public, anon, authenticated;
revoke all on function public.grant_advocacy_reward(uuid, text, text, boolean, text) from public, anon, authenticated;
revoke all on function public.sync_referral_reward_status() from public, anon, authenticated;
grant execute on function public.claim_reward_payout(uuid, timestamptz) to service_role;
grant execute on function public.reconcile_reward_payout(uuid, timestamptz, text) to service_role;
grant execute on function public.expire_reward_credits() to service_role;
grant execute on function public.reward_payout_candidates(integer) to service_role;
grant execute on function public.grant_advocacy_reward(uuid, text, text, boolean, text) to service_role;
grant execute on function public.sync_referral_reward_status() to service_role;
