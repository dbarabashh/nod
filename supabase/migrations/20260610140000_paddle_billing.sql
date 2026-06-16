-- Paddle billing — wires the entitlements schema (20260608130000) to a real
-- Merchant-of-Record provider. Nothing here lets a client grant itself a plan:
-- the only writers are the service-role RPCs below, called exclusively by the
-- `paddle-webhook` Edge Function after it has verified Paddle's signature.
--
--   public.plan_prices    — maps a Paddle `price_id` → (plan, billing cycle) or
--                           a one-time overage pack. The webhook resolves which
--                           plan a payment unlocks from THIS table, so adding a
--                           price/cycle/founding-tier is data, not a release.
--   public.usage_credits  — per-purchase hour packs ("overage, not a hard
--                           stop"). Each row adds hours for one billing period;
--                           the resolver sums the active ones onto hours_limit.
--   public.subscriptions  — gains the Paddle identity columns so webhook events
--                           (keyed by customer/subscription id) find their row.
--
-- The seeded price ids are SANDBOX PLACEHOLDERS — replace each `pri_REPLACE_*`
-- with the real id from the Paddle dashboard (Catalog > Prices) before checkout
-- will work. They're kept as data precisely so swapping them is an UPDATE.

alter table public.subscriptions
    add column if not exists paddle_customer_id     text,
    add column if not exists paddle_subscription_id text,
    add column if not exists paddle_price_id        text;

-- Look up a subscription by its Paddle ids when a webhook event lacks the
-- custom_data.user_id breadcrumb (e.g. an event minted outside our checkout).
create index if not exists subscriptions_paddle_customer_idx
    on public.subscriptions (paddle_customer_id);
create index if not exists subscriptions_paddle_subscription_idx
    on public.subscriptions (paddle_subscription_id);

create table public.plan_prices (
    paddle_price_id text        primary key,
    plan            text        not null references public.plans(plan),
    billing_cycle   text        not null check (billing_cycle in ('monthly', 'yearly', 'one_time')),
    kind            text        not null default 'subscription'
                                check (kind in ('subscription', 'overage')),
    -- One-time packs only: hours this purchase adds to the current period.
    overage_hours   numeric,
    -- Marketing-facing display fields — the paywall is a marketing surface, so
    -- the number/currency shown live next to the price they map to.
    display_amount  numeric     not null,
    currency        text        not null default 'USD',
    is_founding     boolean     not null default false,
    sort_order      int         not null default 0,
    active          boolean     not null default true
);

insert into public.plan_prices
    (paddle_price_id, plan, billing_cycle, kind, overage_hours, display_amount, sort_order) values
    ('pri_REPLACE_starter_yearly',  'starter', 'yearly',   'subscription', null, 9,  1),
    ('pri_REPLACE_starter_monthly', 'starter', 'monthly',  'subscription', null, 14, 2),
    ('pri_REPLACE_pro_yearly',      'pro',     'yearly',   'subscription', null, 19, 3),
    ('pri_REPLACE_pro_monthly',     'pro',     'monthly',  'subscription', null, 29, 4),
    ('pri_REPLACE_starter_overage', 'starter', 'one_time', 'overage',      5,    4,  5),
    ('pri_REPLACE_pro_overage',     'pro',     'one_time', 'overage',      10,   7,  6);

alter table public.plan_prices enable row level security;

-- Active prices are public to any signed-in user — the client renders the
-- paywall from them. Writes are service-role only (no policy).
create policy "authenticated read active plan prices"
    on public.plan_prices
    for select
    to authenticated
    using (active);

-- Per-purchase hour packs. One row per Paddle transaction (idempotent on the
-- transaction id), scoped to the period it was bought in. The resolver adds the
-- hours of rows whose [period_start, period_end) brackets `now()` onto the
-- plan's monthly cap — so a pack expires naturally at the next period.
create table public.usage_credits (
    id                    uuid        primary key default gen_random_uuid(),
    user_id               uuid        not null references auth.users(id) on delete cascade,
    hours                 numeric     not null,
    period_start          timestamptz not null,
    period_end            timestamptz not null,
    paddle_transaction_id text        unique,
    created_at            timestamptz not null default now()
);

create index usage_credits_user_period_idx
    on public.usage_credits (user_id, period_start, period_end);

alter table public.usage_credits enable row level security;

-- Owner can read their packs (drives the "X hours left" UI). No write policy:
-- only the webhook (service role) ever inserts.
create policy "users read own usage credits"
    on public.usage_credits
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Re-define the resolver to fold active overage credits into hours_limit.
-- Identical to 20260608130000 except for the `v_credit_hours` block and its
-- addition to `hours_limit` — kept as a full create-or-replace because the body
-- is one statement and splicing is more error-prone than restating it.
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
    v_base_hours   numeric;
    v_credit_hours numeric;
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

    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.trial_ends_at is not null
       and now() > v_sub.trial_ends_at then
        v_status := 'expired';
    end if;
    v_active := v_status in ('trialing', 'active');

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

    -- Overage packs active right now (bought this period, not yet rolled over).
    select coalesce(sum(hours), 0) into v_credit_hours
    from public.usage_credits
    where user_id = p_user_id
      and period_start <= now()
      and now() < period_end;

    v_base_hours := coalesce((v_limits->>'hours_per_month')::numeric, 0);

    return jsonb_build_object(
        'plan', v_sub.plan,
        'status', v_status,
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_hours_used, 3),
        'hours_limit', case when v_active
                            then v_base_hours + v_credit_hours
                            else 0 end,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;

-- Upsert a user's subscription from a verified Paddle subscription event. The
-- plan is resolved from `plan_prices` (data, not code); the Paddle status is
-- mapped onto our constrained set (paused → past_due, since access is
-- restricted either way and the table has no 'paused' state). Service-role
-- only: the webhook is the sole caller, after signature verification.
create or replace function public.apply_paddle_subscription(
    p_user_id         uuid,
    p_customer_id     text,
    p_subscription_id text,
    p_price_id        text,
    p_paddle_status   text,
    p_period_start    timestamptz,
    p_period_end      timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan   text;
    v_status text;
begin
    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;

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
        updated_at
    ) values (
        p_user_id, coalesce(v_plan, 'starter'), v_status,
        p_period_start, p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        now()
    )
    on conflict (user_id) do update set
        plan                   = coalesce(v_plan, s.plan),
        status                 = v_status,
        current_period_start   = coalesce(p_period_start, s.current_period_start),
        current_period_end     = coalesce(p_period_end, s.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, s.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, s.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, s.paddle_price_id),
        updated_at             = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;

-- Record a one-time hour pack from a verified `transaction.completed` event.
-- Idempotent on the transaction id (Paddle retries webhooks). A price that
-- isn't an overage pack is a no-op, so the webhook can call this for every line
-- item without checking kinds itself.
create or replace function public.apply_paddle_overage(
    p_user_id        uuid,
    p_transaction_id text,
    p_price_id       text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hours numeric;
begin
    select overage_hours into v_hours
    from public.plan_prices
    where paddle_price_id = p_price_id and kind = 'overage';

    if v_hours is null then
        return;
    end if;

    insert into public.usage_credits (user_id, hours, period_start, period_end, paddle_transaction_id)
    values (
        p_user_id, v_hours,
        date_trunc('month', now()),
        date_trunc('month', now()) + interval '1 month',
        p_transaction_id
    )
    on conflict (paddle_transaction_id) do nothing;
end;
$$;

revoke all on function public.apply_paddle_overage(uuid, text, text) from public, anon, authenticated;
grant execute on function public.apply_paddle_overage(uuid, text, text) to service_role;
