-- An organization can hold a plan of its own.
--
-- Until now `subscriptions` was keyed by `user_id` and nothing in the
-- entitlement path consulted `org_members`. An organization could share folders,
-- teams and live rooms, but it could not buy anything: every member paid
-- separately, and the shared surfaces were free riders on whoever happened to be
-- on Pro. This is the table that ends that, plus the plan it holds and the rule
-- for who it covers.
--
-- Seats rather than rows. Paddle bills a per-seat subscription as one
-- subscription with a quantity, so the seat count is a property of the
-- organization's single row and not a row per member. Coverage is therefore
-- derived, not assigned: the first `seats` active members hold the seats, owners
-- first and then by join order. That is deterministic without an assignment UI
-- somebody has to keep correct, and a member who falls outside it is not cut off
-- — they resolve against their own subscription, exactly as they did before the
-- organization bought anything.
--
-- The Teams plan copies Pro's features rather than listing them. Every branch
-- has a different set by now (`action_items`, `ask_live`, `ambient_context` all
-- arrived separately), and a literal list here would be wrong on at least one of
-- them. What Teams adds on top is shared-workspace behaviour, which is already
-- governed by org membership rather than by a feature flag.
--
-- Allowance is 25 hours per seat, pooled. Measured blended cost is $0.379 per
-- audio hour and with the 20% reserve $0.455; a $384/seat/year Teams seat nets
-- $25.29 a month, so 25 hours is where a fully-utilised seat still clears 50%
-- margin. NOD-138 proposed 30, which lands under that before Pipedream is
-- counted at all.
--
-- This migration only creates the shape. The resolver, the webhook path and the
-- seat guard follow in their own migrations so each can be read and reverted on
-- its own.

insert into public.plans (plan, display_name, features, limits, sort_order, purchasable, hours_are_unlimited)
select 'teams', 'Teams', p.features, '{"hours_per_month": 25, "devices": 3}'::jsonb, 3, true, false
  from public.plans p
 where p.plan = 'pro'
on conflict (plan) do nothing;

create table if not exists public.org_subscriptions (
    org_id                 uuid        primary key references public.organizations(id) on delete cascade,
    plan                   text        not null references public.plans(plan),
    status                 text        not null
                                       check (status in ('trialing', 'active', 'past_due', 'canceled', 'expired')),
    -- What the organization is paying for. Paddle carries this as the
    -- subscription item's quantity; everything here reads it from this column so
    -- a seat change is one write.
    seats                  integer     not null default 1 check (seats >= 1),
    current_period_start   timestamptz,
    current_period_end     timestamptz,
    paddle_customer_id     text,
    paddle_subscription_id text        unique,
    paddle_price_id        text,
    -- The person who checked out. Kept for support and for the customer portal,
    -- never for authorization: leaving the organization must not take its
    -- subscription with you.
    purchased_by           uuid        references auth.users(id) on delete set null,
    limit_overrides        jsonb       not null default '{}'::jsonb,
    hours_are_unlimited    boolean,
    converted_at           timestamptz,
    last_paddle_event_at   timestamptz,
    last_paddle_event_id   text,
    updated_at             timestamptz not null default now()
);

alter table public.org_subscriptions enable row level security;

-- Everybody in the organization can see what it is on — a member who cannot
-- start a meeting needs to be told the workspace pool is spent, not handed a
-- silent failure. Nobody writes from a client; the webhook owns this table.
create policy "members read their organization subscription"
    on public.org_subscriptions
    for select
    to authenticated
    using (
        exists (
            select 1 from public.org_members m
             where m.org_id = org_subscriptions.org_id
               and m.user_id = (select auth.uid())
               and m.status = 'active'
        )
    );

revoke all on table public.org_subscriptions from public, anon, authenticated;
grant select on table public.org_subscriptions to authenticated;
grant all on table public.org_subscriptions to service_role;

-- Who the organization is paying for, in join order with owners first.
--
-- Derived on every read rather than stored, so adding a member, suspending one
-- or changing the seat count needs no reconciliation pass. The cost is that
-- coverage is answered as of now: a period that ended while somebody else held
-- the seat is attributed to today's holders. That is acceptable for metering an
-- open period and would not be for invoicing, which Paddle does anyway.
create or replace function public.org_seat_holders(p_org_id uuid)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
    select ranked.user_id
      from (
        select m.user_id,
               row_number() over (order by (m.role <> 'owner'), m.joined_at, m.id) as seat
          from public.org_members m
         where m.org_id = p_org_id
           and m.status = 'active'
      ) ranked
      join public.org_subscriptions os on os.org_id = p_org_id
     where ranked.seat <= os.seats;
$$;

create or replace function public.org_seat_is_held(p_org_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.org_seat_holders(p_org_id) h where h.user_id = p_user_id
    );
$$;

-- Internal helpers for the resolver. Nothing client-facing calls them, and a
-- SECURITY DEFINER function that answers "who is covered" is not something a
-- client should be able to ask about an arbitrary organization.
revoke all on function public.org_seat_holders(uuid) from public, anon, authenticated;
revoke all on function public.org_seat_is_held(uuid, uuid) from public, anon, authenticated;
grant execute on function public.org_seat_holders(uuid) to service_role;
grant execute on function public.org_seat_is_held(uuid, uuid) to service_role;
