-- Referral reward hardening (NOD-22 code-review follow-up). Replaces
-- apply_referral_reward and adds revert_referral_reward. No table changes.
--
-- Fixes:
--   1. Double-pay race — the previous final `update … set status='rewarded'`
--      had no status guard, so two concurrent webhook deliveries for the same
--      referee (subscription.created + .activated, both active) could both
--      return granted=true and pay the referrer twice. The reward is now an
--      ATOMIC CLAIM: only the call that flips activated → rewarded (row_count=1)
--      gets the payout; a concurrent or retried call updates 0 rows and returns
--      already_rewarded. Safe for the retry path too (the UPDATE takes a row
--      lock and re-evaluates the WHERE after the winner commits).
--   2. Unmapped cycle default — coalesce now falls back to 'yearly' (the SAFE
--      defer-renewal path), not 'monthly'. A yearly referrer whose price_id is
--      missing from plan_prices must never get a 100%/1-period discount, which
--      on a yearly plan is a free YEAR.
--   3. Lost-reward recovery — revert_referral_reward lets the webhook release a
--      claim when the Paddle payout fails, so a later subscription event
--      re-claims and retries instead of losing the free month forever.

create or replace function public.apply_referral_reward(
    p_referee_user_id uuid,
    p_code            text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_referrer     uuid;
    v_reward_count int;
    v_sub          public.subscriptions%rowtype;
    v_cycle        text;
    v_claimed      int;
begin
    select user_id into v_referrer from public.referral_codes where code = p_code;
    if v_referrer is null then
        return jsonb_build_object('granted', false, 'reason', 'unknown_code');
    end if;
    if v_referrer = p_referee_user_id then
        return jsonb_build_object('granted', false, 'reason', 'self_referral');
    end if;

    -- Record the friend's conversion. referee_user_id is unique, so a concurrent
    -- first delivery serializes here: the second INSERT blocks until the first
    -- commits, then sees the committed (possibly already-rewarded) row below.
    insert into public.referrals (referrer_user_id, referee_user_id, code, status)
    values (v_referrer, p_referee_user_id, p_code, 'activated')
    on conflict (referee_user_id) do nothing;

    if exists (
        select 1 from public.referrals
        where referee_user_id = p_referee_user_id and status = 'rewarded'
    ) then
        return jsonb_build_object('granted', false, 'reason', 'already_rewarded');
    end if;

    select count(*) into v_reward_count
    from public.referrals
    where referrer_user_id = v_referrer
      and status = 'rewarded'
      and rewarded_at > now() - interval '12 months';
    if v_reward_count >= 6 then
        return jsonb_build_object('granted', false, 'reason', 'cap_reached');
    end if;

    select * into v_sub from public.subscriptions where user_id = v_referrer;
    if v_sub.paddle_subscription_id is null
       or v_sub.status not in ('active', 'past_due') then
        return jsonb_build_object('granted', false, 'reason', 'referrer_not_subscribed');
    end if;

    -- Atomic claim. Only the caller that performs this transition is paid; the
    -- row lock makes a concurrent caller re-check status<>'rewarded' after this
    -- one commits, so it updates 0 rows and bails as already_rewarded.
    update public.referrals
       set status = 'rewarded', rewarded_at = now()
     where referee_user_id = p_referee_user_id
       and status <> 'rewarded';
    get diagnostics v_claimed = row_count;
    if v_claimed = 0 then
        return jsonb_build_object('granted', false, 'reason', 'already_rewarded');
    end if;

    select billing_cycle into v_cycle
    from public.plan_prices where paddle_price_id = v_sub.paddle_price_id;

    return jsonb_build_object(
        'granted', true,
        'referrer_user_id', v_referrer,
        'paddle_subscription_id', v_sub.paddle_subscription_id,
        'billing_cycle', coalesce(v_cycle, 'yearly')
    );
end;
$$;

revoke all on function public.apply_referral_reward(uuid, text) from public, anon, authenticated;
grant execute on function public.apply_referral_reward(uuid, text) to service_role;

-- Release a claim whose Paddle payout failed, so a later subscription event for
-- the same referee re-claims and retries the free-month grant. Service-role only.
create or replace function public.revert_referral_reward(p_referee_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.referrals
       set status = 'activated', rewarded_at = null
     where referee_user_id = p_referee_user_id
       and status = 'rewarded';
end;
$$;

revoke all on function public.revert_referral_reward(uuid) from public, anon, authenticated;
grant execute on function public.revert_referral_reward(uuid) to service_role;
