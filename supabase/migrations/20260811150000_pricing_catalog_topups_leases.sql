-- Tables only. Every function that reads them lands in the next migration so
-- neither half carries a forward reference to the other.

alter table public.plan_prices
    drop constraint if exists plan_prices_kind_check;

alter table public.plan_prices
    add constraint plan_prices_kind_check check (kind in ('subscription', 'topup')),
    add column if not exists sku text,
    add column if not exists top_up_hours numeric,
    add column if not exists available_for_new_checkout boolean not null default true;

create unique index if not exists plan_prices_sku_idx
    on public.plan_prices (sku)
    where sku is not null;

-- The replacement catalog under discussion in NOD-76. Seeded with placeholders
-- (real ids are per-branch data, never a migration) and, critically, with
-- available_for_new_checkout = false: a founder pricing decision plus
-- `cutover_pricing_catalog` is the only path that can expose these to a client.
-- Existing rows keep the column default (true), so live pricing is untouched.
insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, available_for_new_checkout
) values
    ('pri_REPLACE_starter_monthly_15', 'starter', 'monthly', 'subscription', 15, 'USD', false, 11, true, 'starter_monthly_usd_15', null, false),
    ('pri_REPLACE_starter_yearly_144', 'starter', 'yearly', 'subscription', 12, 'USD', false, 12, true, 'starter_yearly_usd_144', null, false),
    ('pri_REPLACE_pro_monthly_24', 'pro', 'monthly', 'subscription', 24, 'USD', false, 13, true, 'pro_monthly_usd_24', null, false),
    ('pri_REPLACE_pro_yearly_240', 'pro', 'yearly', 'subscription', 20, 'USD', false, 14, true, 'pro_yearly_usd_240', null, false),
    ('pri_REPLACE_starter_topup_5h_12', 'starter', 'one_time', 'topup', 12, 'USD', false, 20, true, 'starter_5h_usd_12', 5, false)
on conflict (paddle_price_id) do update set
    plan = excluded.plan,
    billing_cycle = excluded.billing_cycle,
    kind = excluded.kind,
    display_amount = excluded.display_amount,
    currency = excluded.currency,
    sort_order = excluded.sort_order,
    active = excluded.active,
    sku = excluded.sku,
    top_up_hours = excluded.top_up_hours,
    available_for_new_checkout = excluded.available_for_new_checkout;

-- A client may only read what it could actually buy, so a dark catalog can't
-- leak into the paywall while the pricing decision is still open.
drop policy if exists "authenticated read active plan prices" on public.plan_prices;
create policy "authenticated read checkout plan prices"
    on public.plan_prices
    for select
    to authenticated
    using (active and available_for_new_checkout);

-- A top-up is bound to the billing period it was bought for, so a period that
-- rolls over between checkout and payment routes to reconciliation instead of
-- silently crediting the wrong month.
create table public.topup_checkout_intents (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    paddle_subscription_id text not null,
    paddle_price_id text not null references public.plan_prices(paddle_price_id),
    sku text not null check (sku = 'starter_5h_usd_12'),
    period_start timestamptz not null,
    period_end timestamptz not null,
    included_seconds numeric not null check (included_seconds >= 0),
    expires_at timestamptz not null,
    paddle_transaction_id text unique,
    status text not null default 'created'
        check (status in ('created', 'checkout_created', 'fulfilled', 'reconciliation_required', 'canceled')),
    reconciliation_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint topup_checkout_intents_valid_period check (period_end > period_start),
    constraint topup_checkout_intents_valid_expiry check (expires_at > created_at)
);

create index topup_checkout_intents_user_idx
    on public.topup_checkout_intents (user_id, created_at desc);

alter table public.topup_checkout_intents enable row level security;

create policy "users read own topup checkout intents"
    on public.topup_checkout_intents
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create table public.usage_topups (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    paddle_transaction_id text not null unique,
    paddle_price_id text not null references public.plan_prices(paddle_price_id),
    hours numeric not null check (hours > 0),
    included_seconds numeric not null check (included_seconds >= 0),
    period_start timestamptz not null,
    period_end timestamptz not null,
    status text not null default 'active'
        check (status in ('active', 'refunded', 'review_required')),
    refunded_at timestamptz,
    refund_reason text,
    created_at timestamptz not null default now(),
    constraint usage_topups_valid_period check (period_end > period_start)
);

create index usage_topups_user_period_idx
    on public.usage_topups (user_id, period_start, period_end)
    where status = 'active';

alter table public.usage_topups enable row level security;

create policy "users read own usage topups"
    on public.usage_topups
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- The allowance is enforced when a meeting STARTS, never mid-recording: a lease
-- is granted once, then every transcription chunk presents it. The TTL is short
-- and renewed by use, so a crashed or offline client frees its own slot in
-- minutes instead of locking recording out for hours.
create table public.meeting_start_leases (
    meeting_id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    status text not null default 'active' check (status in ('active', 'ended')),
    granted_at timestamptz not null default now(),
    expires_at timestamptz not null,
    ended_at timestamptz,
    last_used_at timestamptz,
    constraint meeting_start_leases_valid_expiry check (expires_at > granted_at)
);

create index meeting_start_leases_user_active_idx
    on public.meeting_start_leases (user_id, expires_at desc)
    where status = 'active';

alter table public.meeting_start_leases enable row level security;

create policy "users read own meeting start leases"
    on public.meeting_start_leases
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Enforcement stays off until a build that speaks the lease protocol is the
-- minimum. 2147483647 means "no build qualifies yet".
alter table public.app_config
    add column if not exists meeting_lease_required_build integer not null default 2147483647;

revoke all on table public.topup_checkout_intents from public, anon, authenticated;
revoke all on table public.usage_topups from public, anon, authenticated;
revoke all on table public.meeting_start_leases from public, anon, authenticated;

grant select on table public.topup_checkout_intents to authenticated;
grant select on table public.usage_topups to authenticated;
grant select on table public.meeting_start_leases to authenticated;

grant all on table public.topup_checkout_intents to service_role;
grant all on table public.usage_topups to service_role;
grant all on table public.meeting_start_leases to service_role;
