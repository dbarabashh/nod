-- Entitlements — plan → feature mapping kept as DATA, not as if/else in the
-- app binary. Two tables and one resolver:
--
--   public.plans          — the catalog. One row per plan; `features` (text[])
--                           and `limits` (jsonb) say what each plan grants.
--                           Changing what a plan unlocks is an UPDATE here,
--                           never a client release.
--   public.subscriptions  — one row per user: which plan they're on, status,
--                           trial window, plus PER-USER overrides
--                           (`feature_overrides`, `limit_overrides`) that layer
--                           on top of the plan. This is what makes
--                           "founding members keep Pro forever" expressible
--                           without a special-case `if` — it's just a row whose
--                           overrides differ from the current plan default.
--   public.resolve_entitlement(p_user_id) — resolves plan defaults + per-user
--                           overrides + live usage into one object. Service
--                           role only: the llm-proxy calls it to ENFORCE
--                           status and hour caps at the chokepoint.
--   public.get_entitlement() — the client RPC; a wrapper that pins the
--                           resolver to auth.uid(). The client never knows
--                           what a plan contains; it only asks "what do I
--                           have right now".
--
-- No payment provider yet. Subscriptions are created as a 14-day trial on
-- signup (trigger below) and can be moved between plans manually with the
-- service role for local testing. A future Paddle webhook is the only thing
-- that writes here in production — there are deliberately no client write
-- policies on `subscriptions`.

create table public.plans (
    plan         text        primary key,
    display_name text        not null,
    features     text[]      not null default '{}',
    limits       jsonb       not null default '{}'::jsonb,
    sort_order   int         not null default 0,
    purchasable  boolean     not null default true
);

-- Seeded from docs/pricing.md. Trial == the full Pro experience for 14 days,
-- so it carries Pro's feature set and limits.
insert into public.plans (plan, display_name, features, limits, sort_order, purchasable) values
    ('trial', 'Trial', array[
        'live_transcription', 'ask_single_meeting', 'multilingual', 'unlimited_history',
        'ask_across_meetings', 'label_scoping'
     ], '{"hours_per_month": 50, "devices": 3}'::jsonb, 0, false),
    ('starter', 'Starter', array[
        'live_transcription', 'ask_single_meeting', 'multilingual', 'unlimited_history'
     ], '{"hours_per_month": 15, "devices": 1}'::jsonb, 1, true),
    ('pro', 'Pro', array[
        'live_transcription', 'ask_single_meeting', 'multilingual', 'unlimited_history',
        'ask_across_meetings', 'label_scoping'
     ], '{"hours_per_month": 50, "devices": 3}'::jsonb, 2, true);

alter table public.plans enable row level security;

-- The catalog is public to any signed-in user — the client reads it to render
-- the paywall / plan comparison. Writes are service-role only (no policy).
create policy "authenticated read plans"
    on public.plans
    for select
    to authenticated
    using (true);

create table public.subscriptions (
    user_id              uuid        primary key references auth.users(id) on delete cascade,
    plan                 text        not null references public.plans(plan),
    status               text        not null default 'trialing'
                                     check (status in ('trialing', 'active', 'past_due', 'canceled', 'expired')),
    current_period_start timestamptz not null default now(),
    current_period_end   timestamptz,
    trial_ends_at        timestamptz,
    -- Layered on top of the plan's defaults. `feature_overrides` is unioned
    -- with `plans.features`; `limit_overrides` is merged key-by-key over
    -- `plans.limits` (the override wins). Empty = "just use the plan default".
    feature_overrides    text[]      not null default '{}',
    limit_overrides      jsonb       not null default '{}'::jsonb,
    updated_at           timestamptz not null default now()
);

alter table public.subscriptions enable row level security;

-- Owner can read their subscription (drives the client entitlement + paywall).
-- No insert/update/delete policy: only the trigger below (security definer)
-- and the future billing webhook (service role) ever write here. A client
-- must never be able to grant itself a plan.
create policy "users read own subscription"
    on public.subscriptions
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Every new user starts a 14-day trial (no card). On conflict do nothing so a
-- re-fired insert (or a manual backfill race) never clobbers an existing row.
create or replace function public.handle_new_user_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.subscriptions (user_id, plan, status, current_period_start, trial_ends_at)
    values (new.id, 'trial', 'trialing', now(), now() + interval '14 days')
    on conflict (user_id) do nothing;
    return new;
end;
$$;

create trigger on_auth_user_created_subscription
    after insert on auth.users
    for each row execute function public.handle_new_user_subscription();

-- Backfill existing users so everyone has an entitlement to resolve.
insert into public.subscriptions (user_id, plan, status, current_period_start, trial_ends_at)
select id, 'trial', 'trialing', now(), now() + interval '14 days'
from auth.users
on conflict (user_id) do nothing;

-- The resolver. Computes a user's effective entitlement:
--   plan defaults  ∪  per-user feature overrides
--   plan limits    +  per-user limit overrides (override wins)
--   live usage     →  hours_used in the current billing/trial period
--
-- SECURITY DEFINER with an explicit p_user_id, because it serves two callers:
-- the llm-proxy (service role) enforcing quota server-side, and the
-- get_entitlement() wrapper below for the client. It is deliberately NOT
-- executable by authenticated/anon — exposing it would let any signed-in user
-- pass an arbitrary p_user_id and read another user's plan and usage.
-- A trial that has run past `trial_ends_at` resolves to status 'expired' with
-- an empty feature set, so the client gates everything off and shows a paywall
-- while history (governed by other tables' RLS) stays readable.
create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub          public.subscriptions%rowtype;
    v_plan         public.plans%rowtype;
    v_status       text;
    v_active       boolean;
    v_features     text[];
    v_limits       jsonb;
    v_period_start timestamptz;
    v_period_end   timestamptz;
    v_hours_used   numeric;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;
    if not found then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'trial_ends_at', null, 'renewal_date', null
        );
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;

    -- Effective status: a trial whose clock has run out is expired, even if no
    -- billing job has flipped the stored status yet.
    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.trial_ends_at is not null
       and now() > v_sub.trial_ends_at then
        v_status := 'expired';
    end if;
    v_active := v_status in ('trialing', 'active');

    -- Usage window. Trial meters across the whole trial; paid meters per
    -- calendar month. With no provider rolling `current_period_*`, fall back
    -- to the current calendar month once the stored window has elapsed.
    if v_status = 'trialing' then
        v_period_start := v_sub.current_period_start;
        v_period_end   := coalesce(v_sub.trial_ends_at, now() + interval '100 years');
    else
        v_period_start := coalesce(v_sub.current_period_start, date_trunc('month', now()));
        v_period_end   := coalesce(v_sub.current_period_end, v_period_start + interval '1 month');
        if now() >= v_period_end then
            v_period_start := date_trunc('month', now());
            v_period_end   := v_period_start + interval '1 month';
        end if;
    end if;

    v_features := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    v_limits   := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);

    select coalesce(sum(audio_seconds), 0) / 3600.0 into v_hours_used
    from public.usage_events
    where user_id = p_user_id
      and kind = 'transcribe'
      and created_at >= v_period_start
      and created_at <  v_period_end;

    return jsonb_build_object(
        'plan', v_sub.plan,
        'status', v_status,
        -- Locked accounts (expired/canceled) report no features so the client
        -- gates everything off in one place — the gate never special-cases
        -- status, it just reads this list.
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_hours_used, 3),
        'hours_limit', case when v_active
                            then coalesce((v_limits->>'hours_per_month')::numeric, 0)
                            else 0 end,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_period_end
    );
end;
$$;

-- Functions are executable by PUBLIC by default — strip that, then grant the
-- resolver to the service role only.
revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;

-- The one call the client makes. SECURITY DEFINER so it may invoke the
-- resolver (which authenticated has no execute on); safe because the user id
-- is pinned to auth.uid() — a caller can only ever resolve themselves.
create or replace function public.get_entitlement()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_uid uuid := (select auth.uid());
begin
    if v_uid is null then
        return jsonb_build_object('error', 'unauthenticated');
    end if;
    return public.resolve_entitlement(v_uid);
end;
$$;

revoke all on function public.get_entitlement() from public, anon;
grant execute on function public.get_entitlement() to authenticated;
