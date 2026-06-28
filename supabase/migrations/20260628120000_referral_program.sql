-- Referral / bonus program (NOD-22, Phase 2).
--
-- Reward currency is Paddle discounts / subscription time, NOT bonus hours — so
-- nothing here touches the metering/quota hot path. Two tables + two RPCs:
--
--   public.referral_codes  — one stable code per user. Carries ATTRIBUTION only
--                            (which referrer to credit); it is NOT a Paddle
--                            coupon. The friend's −50% comes from a single
--                            static Paddle discount reused for every referred
--                            checkout (its id lives in a per-branch secret,
--                            never here), applied client-side in create-checkout.
--   public.referrals       — one row per referred friend. `referee_user_id` is
--                            UNIQUE (a user can only ever be referred once) and a
--                            CHECK forbids self-referral. status is 'activated'
--                            once the friend converts and 'rewarded' once the
--                            referrer is paid (see 20260628140000 for the
--                            atomic-claim + retry semantics). 'pending' is
--                            reserved/unused by the current flow.
--
--   get_or_create_referral_code()              — client RPC, idempotent, pinned
--                                                to auth.uid(). Mints/returns the
--                                                caller's stable code.
--   apply_referral_reward(referee, code)       — service-role RPC, called by
--                                                paddle-webhook on the friend's
--                                                first PAID activation. Runs all
--                                                guards (self/dup/cap/subscribed)
--                                                in one transaction, advances the
--                                                row, and returns the referrer's
--                                                Paddle subscription id + cycle so
--                                                the webhook can pay out the free
--                                                month (monthly: 100%/1-period
--                                                discount; yearly: defer renewal
--                                                ~1 month — never a free year).
--
-- The reward is the only writer of `status='rewarded'`; the annual cap (6
-- rewarded referrals / rolling 12 months) is enforced inside the RPC, not in the
-- app. No client write policies on either table — same posture as subscriptions.

create table public.referral_codes (
    code       text        primary key,
    user_id    uuid        not null unique references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);

alter table public.referral_codes enable row level security;

-- Owner can read their own code (drives the Rewards screen). No write policy:
-- only get_or_create_referral_code (security definer) ever inserts.
create policy "users read own referral code"
    on public.referral_codes
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create table public.referrals (
    id               uuid        primary key default gen_random_uuid(),
    referrer_user_id uuid        not null references auth.users(id) on delete cascade,
    -- A user can be referred at most once, ever — blocks duplicate-referee abuse.
    referee_user_id  uuid        not null unique references auth.users(id) on delete cascade,
    code             text        not null,
    status           text        not null default 'pending'
                                 check (status in ('pending', 'activated', 'rewarded')),
    created_at       timestamptz not null default now(),
    rewarded_at      timestamptz,
    constraint referrals_no_self_referral check (referrer_user_id <> referee_user_id)
);

create index referrals_referrer_idx on public.referrals (referrer_user_id);

alter table public.referrals enable row level security;

-- Referrer reads their own referrals (status counts for the Rewards screen).
-- No write policy: only apply_referral_reward (service role) writes.
create policy "referrer reads own referrals"
    on public.referrals
    for select
    to authenticated
    using ((select auth.uid()) = referrer_user_id);

-- Mint or return the caller's stable referral code. Idempotent: a user always
-- gets the same code back. Pinned to auth.uid() so a caller can only ever mint
-- their own. Codes use an unambiguous alphabet (no 0/O/1/I/L) so they survive
-- being read off a screen or typed by hand.
create or replace function public.get_or_create_referral_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid      uuid := (select auth.uid());
    v_code     text;
    v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    i          int;
begin
    if v_uid is null then
        raise exception 'unauthenticated';
    end if;

    select code into v_code from public.referral_codes where user_id = v_uid;
    if v_code is not null then
        return v_code;
    end if;

    for _attempt in 1..10 loop
        v_code := '';
        for i in 1..6 loop
            v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
        end loop;
        begin
            insert into public.referral_codes (code, user_id) values (v_code, v_uid);
            return v_code;
        exception when unique_violation then
            -- Either a code collision (retry with a fresh code) or this user
            -- raced another insert of their OWN row (return that one).
            select code into v_code from public.referral_codes where user_id = v_uid;
            if v_code is not null then
                return v_code;
            end if;
        end;
    end loop;

    raise exception 'could not allocate referral code';
end;
$$;

revoke all on function public.get_or_create_referral_code() from public, anon;
grant execute on function public.get_or_create_referral_code() to authenticated;

-- Credit a referrer for a friend's first PAID activation. Service-role only:
-- the webhook is the sole caller, after signature verification. Idempotent on
-- the referee (Paddle retries webhooks) — a referee already 'rewarded' returns
-- granted=false so the payout fires at most once.
--
-- Returns a jsonb verdict. On granted=true the caller (webhook) performs the
-- Paddle payout using `paddle_subscription_id` + `billing_cycle`. Cases that
-- still record the friend joined (status='activated') but pay nothing return
-- granted=false with a reason: cap_reached, referrer_not_subscribed,
-- self_referral, unknown_code, already_rewarded.
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
    v_existing     public.referrals%rowtype;
    v_reward_count int;
    v_sub          public.subscriptions%rowtype;
    v_cycle        text;
begin
    select user_id into v_referrer from public.referral_codes where code = p_code;
    if v_referrer is null then
        return jsonb_build_object('granted', false, 'reason', 'unknown_code');
    end if;
    if v_referrer = p_referee_user_id then
        return jsonb_build_object('granted', false, 'reason', 'self_referral');
    end if;

    select * into v_existing from public.referrals where referee_user_id = p_referee_user_id;
    if found and v_existing.status = 'rewarded' then
        return jsonb_build_object('granted', false, 'reason', 'already_rewarded');
    end if;

    -- Record that the friend joined regardless of whether the reward fires.
    -- referee_user_id is unique, so a re-fired webhook just no-ops the insert.
    insert into public.referrals (referrer_user_id, referee_user_id, code, status)
    values (v_referrer, p_referee_user_id, p_code, 'activated')
    on conflict (referee_user_id) do update
        set status = 'activated'
        where public.referrals.status = 'pending';

    -- Annual cap: at most 6 rewarded referrals per rolling 12 months.
    select count(*) into v_reward_count
    from public.referrals
    where referrer_user_id = v_referrer
      and status = 'rewarded'
      and rewarded_at > now() - interval '12 months';
    if v_reward_count >= 6 then
        return jsonb_build_object('granted', false, 'reason', 'cap_reached');
    end if;

    -- Option 1 payout pays a free month onto the referrer's live Paddle
    -- subscription — so they must have one. A referrer with no active sub can't
    -- be paid this way; record the join and skip.
    select * into v_sub from public.subscriptions where user_id = v_referrer;
    if v_sub.paddle_subscription_id is null
       or v_sub.status not in ('active', 'past_due') then
        return jsonb_build_object('granted', false, 'reason', 'referrer_not_subscribed');
    end if;

    select billing_cycle into v_cycle
    from public.plan_prices where paddle_price_id = v_sub.paddle_price_id;

    update public.referrals
    set status = 'rewarded', rewarded_at = now()
    where referee_user_id = p_referee_user_id;

    return jsonb_build_object(
        'granted', true,
        'referrer_user_id', v_referrer,
        'paddle_subscription_id', v_sub.paddle_subscription_id,
        'billing_cycle', coalesce(v_cycle, 'monthly')
    );
end;
$$;

revoke all on function public.apply_referral_reward(uuid, text) from public, anon, authenticated;
grant execute on function public.apply_referral_reward(uuid, text) to service_role;
