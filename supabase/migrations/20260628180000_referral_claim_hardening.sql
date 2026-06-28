-- Referral claim hardening (NOD-22 code-review round 2). Replaces
-- claim_referral_rewards. No table changes.
--
-- Fixes:
--   1. Cap race + double-defer (concurrent claims) — two webhook deliveries that
--      both claim for the SAME referrer were only protected at the row level
--      (FOR UPDATE SKIP LOCKED), not the aggregate: each read the rewarded count
--      unlocked and each grabbed different 'earned' rows, so they could exceed
--      the 6/12-month cap AND both defer next_billed_at from the same base date
--      (losing a month). A per-referrer advisory lock now serializes claims —
--      the first claim consumes all claimable rows, so the second sees none and
--      pays nothing.
--   2. past_due payout — a past_due subscription can have next_billed_at in the
--      past, so deferring it grants little/no real free time while burning the
--      earned rows. Only 'active' subscriptions are paid now; a recovered
--      referrer is claimed on their next active event.
--   3. Hot-path cost — claim runs on every active subscription webhook for every
--      user. A cheap EXISTS short-circuit returns immediately for the ~99% who
--      have no earned referrals, before taking any lock or touching billing rows.

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
    -- Fast path: nothing earned → no lock, no billing lookup.
    if not exists (
        select 1 from public.referrals
        where referrer_user_id = p_referrer_user_id and status = 'earned'
    ) then
        return jsonb_build_object('count', 0);
    end if;

    -- Serialize all claims for this referrer so the cap and the next_billed_at
    -- read-modify-write can't race across concurrent webhook deliveries.
    perform pg_advisory_xact_lock(hashtext('referral_claim:' || p_referrer_user_id::text));

    -- Only a live, paying ('active') subscription can receive a renewal defer.
    -- past_due/trialing → hold the earned months; claimed on the next active event.
    select * into v_sub from public.subscriptions where user_id = p_referrer_user_id;
    if v_sub.paddle_subscription_id is null or v_sub.status <> 'active' then
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
         for update
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
