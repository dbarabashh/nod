-- Referral retention gate + accumulate-and-claim (NOD-22 follow-up).
--
-- Two product changes on top of 20260628140000:
--
--   1. Retention gate — the referrer's free month is no longer granted on the
--      friend's FIRST payment. It's earned only once the friend is charged for a
--      NEW billing period (their first renewal, ~30 days), proving they didn't
--      pay once at −50% and churn. No cron: the renewal's own webhook is the
--      trigger.
--   2. Accumulate & claim — a referrer who isn't a paying subscriber still
--      accrues earned months; they sit 'earned' (claimable) and are paid out the
--      moment the referrer has an active subscription. This converts referrers to
--      paid: "you have N free months waiting — subscribe to claim them."
--
-- New status lifecycle:
--   activated → friend made their first payment (no reward yet)
--   earned    → friend retained into a new billing period (reward owed; held if
--               the referrer isn't subscribed yet)
--   rewarded  → free month actually granted to the referrer
--
-- Payout (in paddle-webhook) is now a uniform "defer next_billed_at by N months"
-- for any cycle — so a referrer can collect several accrued months at once, and
-- the old 100%-discount path (and its free-year-on-yearly hazard) is gone.

alter table public.referrals drop constraint referrals_status_check;
alter table public.referrals
    add constraint referrals_status_check
    check (status in ('pending', 'activated', 'earned', 'rewarded'));

alter table public.referrals add column if not exists earned_at timestamptz;

-- Superseded by process_referee_payment + claim_referral_rewards below.
drop function if exists public.apply_referral_reward(uuid, text);
drop function if exists public.revert_referral_reward(uuid);

-- Called by paddle-webhook on a referred friend's status=active events. Creates
-- the referral on first payment ('activated'); promotes it to 'earned' once the
-- friend is billed for a new period (retention proven). Idempotent and
-- race-safe. Returns {action, referrer_user_id?}.
create or replace function public.process_referee_payment(
    p_referee_user_id uuid,
    p_code            text,
    p_period_start    timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_referrer uuid;
    v_row      public.referrals%rowtype;
    v_n        int;
begin
    select user_id into v_referrer from public.referral_codes where code = p_code;
    if v_referrer is null then
        return jsonb_build_object('action', 'unknown_code');
    end if;
    if v_referrer = p_referee_user_id then
        return jsonb_build_object('action', 'self_referral');
    end if;

    select * into v_row from public.referrals where referee_user_id = p_referee_user_id;
    if not found then
        insert into public.referrals (referrer_user_id, referee_user_id, code, status)
        values (v_referrer, p_referee_user_id, p_code, 'activated')
        on conflict (referee_user_id) do nothing;
        return jsonb_build_object('action', 'activated');
    end if;

    if v_row.status <> 'activated' then
        return jsonb_build_object('action', 'noop');
    end if;

    -- Retention: only once the friend is billed for a period that starts clearly
    -- after their first payment (a real renewal). 20 days cleanly separates the
    -- initial period from the next monthly cycle (shortest month is 28 days).
    if p_period_start is null or p_period_start <= v_row.created_at + interval '20 days' then
        return jsonb_build_object('action', 'noop');
    end if;

    update public.referrals
       set status = 'earned', earned_at = now()
     where referee_user_id = p_referee_user_id and status = 'activated';
    get diagnostics v_n = row_count;
    if v_n = 0 then
        return jsonb_build_object('action', 'noop');
    end if;

    return jsonb_build_object('action', 'earned', 'referrer_user_id', v_referrer);
end;
$$;

revoke all on function public.process_referee_payment(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.process_referee_payment(uuid, text, timestamptz) to service_role;

-- Called by paddle-webhook for any user whose subscription is active — pays out
-- as many of their 'earned' referrals as the annual cap allows, but ONLY if they
-- have a live paid subscription (the conversion lever: earned months are held
-- until the referrer is subscribed). Atomic via FOR UPDATE SKIP LOCKED so
-- concurrent webhook deliveries can't pay the same rows twice. Returns
-- {count, ids, paddle_subscription_id}; the webhook defers renewal by `count`
-- months, then confirms or releases the claim.
create or replace function public.claim_referral_rewards(p_referrer_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_sub       public.subscriptions%rowtype;
    v_used      int;
    v_remaining int;
    v_ids       uuid[];
begin
    select * into v_sub from public.subscriptions where user_id = p_referrer_user_id;
    if v_sub.paddle_subscription_id is null or v_sub.status not in ('active', 'past_due') then
        return jsonb_build_object('count', 0, 'reason', 'not_subscribed');
    end if;

    select count(*) into v_used
    from public.referrals
    where referrer_user_id = p_referrer_user_id
      and status = 'rewarded'
      and rewarded_at > now() - interval '12 months';
    v_remaining := 6 - v_used;
    if v_remaining <= 0 then
        return jsonb_build_object('count', 0, 'reason', 'cap_reached');
    end if;

    select array_agg(id) into v_ids from (
        select id from public.referrals
         where referrer_user_id = p_referrer_user_id and status = 'earned'
         order by earned_at
         limit v_remaining
         for update skip locked
    ) s;
    if v_ids is null then
        return jsonb_build_object('count', 0);
    end if;

    update public.referrals set status = 'rewarded', rewarded_at = now()
     where id = any(v_ids);

    return jsonb_build_object(
        'count', array_length(v_ids, 1),
        'ids', to_jsonb(v_ids),
        'paddle_subscription_id', v_sub.paddle_subscription_id
    );
end;
$$;

revoke all on function public.claim_referral_rewards(uuid) from public, anon, authenticated;
grant execute on function public.claim_referral_rewards(uuid) to service_role;

-- Release a claim whose Paddle payout failed, so a later subscription event
-- re-claims and retries. Takes the ids returned by claim_referral_rewards.
create or replace function public.revert_referral_claim(p_ids text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.referrals set status = 'earned', rewarded_at = null
     where id = any(p_ids::uuid[]) and status = 'rewarded';
end;
$$;

revoke all on function public.revert_referral_claim(text[]) from public, anon, authenticated;
grant execute on function public.revert_referral_claim(text[]) to service_role;
