-- Coverage stops moving under people, and a seat cut is written down.
--
-- Two ways an active member could lose their seat without anybody being told:
--
--   1. A role change. `org_seat_holders` ranked owners first and then by join
--      order, so promoting the newest member to owner pushed somebody else out
--      of the seat count with no event, no notification and no audit row.
--      Owners-first was meant to protect the purchaser from being squeezed out,
--      but the purchaser created the organization and is first by join order
--      anyway. Coverage is now join order alone: deterministic, and immune to
--      anything an administrator does on the People page.
--
--   2. A seat reduction made in Paddle's own portal. `create-checkout` refuses
--      to buy fewer seats than there are people, but Paddle emails every
--      customer a portal link and a quantity edited there arrives as a webhook
--      that `apply_paddle_org_subscription` simply applied. The event cannot be
--      refused — the seats are already gone on Paddle's side — so it is written
--      to `audit_log` with how many people it left uncovered. The Billing page
--      already names them; this is what lets an administrator learn it happened
--      without opening that page.
--
-- Same rule in `org_billing_overview`, so the table on the Billing page and the
-- resolver never disagree about who holds a seat.

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
               row_number() over (order by m.joined_at, m.id) as seat
          from public.org_members m
         where m.org_id = p_org_id
           and m.status = 'active'
      ) ranked
      join public.org_subscriptions os on os.org_id = p_org_id
     where ranked.seat <= os.seats;
$$;

revoke all on function public.org_seat_holders(uuid) from public, anon, authenticated;
grant execute on function public.org_seat_holders(uuid) to service_role;

create or replace function public.apply_paddle_org_subscription(
    p_org_id            uuid,
    p_customer_id       text,
    p_subscription_id   text,
    p_price_id          text,
    p_paddle_status     text,
    p_seats             integer,
    p_period_start      timestamptz,
    p_period_end        timestamptz,
    p_event_id          text,
    p_event_occurred_at timestamptz,
    p_purchased_by      uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan text;
    v_existing_plan text;
    v_existing_seats integer;
    v_existing_event_at timestamptz;
    v_existing_event_id text;
    v_status text;
    v_seats integer;
    v_active_members integer;
begin
    if p_org_id is null then
        raise exception 'apply_paddle_org_subscription: organization required';
    end if;
    if nullif(trim(p_event_id), '') is null or p_event_occurred_at is null then
        raise exception 'apply_paddle_org_subscription: event identity required';
    end if;

    perform pg_advisory_xact_lock(hashtext('paddle_org_subscription:' || p_org_id::text));

    select plan, seats, last_paddle_event_at, last_paddle_event_id
      into v_existing_plan, v_existing_seats, v_existing_event_at, v_existing_event_id
      from public.org_subscriptions
     where org_id = p_org_id
     for update;
    if found
       and v_existing_event_at is not null
       and p_event_occurred_at <= v_existing_event_at then
        return false;
    end if;

    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    if v_plan is null then
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_org_subscription: unmapped paddle price_id %', p_price_id;
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

    -- A cancellation event carries no meaningful quantity, so it must not shrink
    -- the organization to one seat on its way out.
    v_seats := greatest(coalesce(p_seats, 0), 1);

    insert into public.org_subscriptions as o (
        org_id, plan, status, seats,
        current_period_start, current_period_end,
        paddle_customer_id, paddle_subscription_id, paddle_price_id,
        purchased_by, converted_at, updated_at,
        last_paddle_event_at, last_paddle_event_id
    ) values (
        p_org_id, v_plan, v_status, v_seats,
        coalesce(p_period_start, p_event_occurred_at), p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        p_purchased_by,
        case when v_status in ('active', 'past_due') then p_event_occurred_at end,
        now(), p_event_occurred_at, p_event_id
    )
    on conflict (org_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        seats                  = case when p_seats is null then o.seats else v_seats end,
        current_period_start   = coalesce(p_period_start, o.current_period_start),
        current_period_end     = coalesce(p_period_end, o.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, o.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, o.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, o.paddle_price_id),
        purchased_by           = coalesce(o.purchased_by, p_purchased_by),
        limit_overrides        = case
                                    when o.plan is distinct from v_plan
                                    then coalesce(o.limit_overrides, '{}'::jsonb) - 'hours_per_month'
                                    else o.limit_overrides
                                 end,
        hours_are_unlimited    = case
                                    when o.plan is distinct from v_plan
                                    then null
                                    else o.hours_are_unlimited
                                 end,
        converted_at           = case
                                    when v_status in ('active', 'past_due')
                                    then coalesce(o.converted_at, p_event_occurred_at)
                                    else o.converted_at
                                 end,
        updated_at             = now(),
        last_paddle_event_at   = p_event_occurred_at,
        last_paddle_event_id   = p_event_id;

    -- A cut that leaves people outside the seat count happened on Paddle's side
    -- and cannot be undone here, so it is recorded where an administrator will
    -- find it. No actor: the portal is Paddle's surface, not a member's action.
    if p_seats is not null
       and v_existing_seats is not null
       and v_seats < v_existing_seats then
        select count(*) into v_active_members
          from public.org_members
         where org_id = p_org_id and status = 'active';
        if v_active_members > v_seats then
            insert into public.audit_log (org_id, actor_user_id, action, target_type, metadata)
            values (
                p_org_id, null, 'billing.seats_reduced_below_members', 'organization',
                jsonb_build_object(
                    'seats_before', v_existing_seats,
                    'seats_after', v_seats,
                    'active_members', v_active_members,
                    'uncovered', v_active_members - v_seats,
                    'paddle_event_id', p_event_id
                )
            );
        end if;
    end if;

    return true;
end;
$$;

revoke all on function public.apply_paddle_org_subscription(uuid, text, text, text, text, integer, timestamptz, timestamptz, text, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.apply_paddle_org_subscription(uuid, text, text, text, text, integer, timestamptz, timestamptz, text, timestamptz, uuid) to service_role;

create or replace function public.org_billing_overview(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub        public.org_subscriptions%rowtype;
    v_plan       public.plans%rowtype;
    v_window     record;
    v_status     text;
    v_consumed   numeric;
    v_included   numeric;
    v_members    jsonb;
    v_role       text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select m.role into v_role
      from public.org_members m
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active';
    if v_role is null then
        raise exception 'not a member of this organization' using errcode = '42501';
    end if;

    select * into v_sub from public.org_subscriptions where org_id = p_org_id;
    if not found then
        return jsonb_build_object('has_subscription', false, 'viewer_role', v_role);
    end if;

    -- The page says the trial is over even when Paddle has not yet said so,
    -- exactly as the resolver stops honouring it.
    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.current_period_end is not null
       and now() > v_sub.current_period_end then
        v_status := 'expired';
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;
    select * into v_window from public.monthly_usage_window(
        v_status, v_sub.current_period_end, v_sub.current_period_start, v_sub.current_period_end);

    -- The same attribution the resolver uses, so the page and the gate agree.
    select coalesce(sum(u.audio_seconds), 0) into v_consumed
      from public.usage_events u
     where u.kind = 'transcribe'
       and u.created_at >= v_window.period_start
       and u.created_at <  v_window.period_end
       and (
             u.org_id = p_org_id
             or (u.org_id is null
                 and u.user_id in (select h.user_id from public.org_seat_holders(p_org_id) h))
       );

    v_included := case
        when v_status in ('trialing', 'active')
        then coalesce(((coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb))
                       ->>'hours_per_month')::numeric, 0) * 3600 * v_sub.seats
        else 0
    end;

    select coalesce(jsonb_agg(row_to_json(entry)::jsonb order by entry.seat), '[]'::jsonb)
      into v_members
      from (
        select m.user_id,
               coalesce(p.display_name, u.email) as name,
               u.email,
               m.role,
               row_number() over (order by m.joined_at, m.id) as seat,
               row_number() over (order by m.joined_at, m.id) <= v_sub.seats as holds_seat
          from public.org_members m
          join auth.users u on u.id = m.user_id
          left join public.profiles p on p.user_id = m.user_id
         where m.org_id = p_org_id
           and m.status = 'active'
      ) entry;

    return jsonb_build_object(
        'has_subscription', true,
        'viewer_role', v_role,
        'plan', v_sub.plan,
        'status', v_status,
        'seats', v_sub.seats,
        'billing_cycle', (select billing_cycle from public.plan_prices
                           where paddle_price_id = v_sub.paddle_price_id),
        'hours_included', round(v_included / 3600.0, 3),
        'hours_used', round(v_consumed / 3600.0, 3),
        'trial_ends_at', case when v_status = 'trialing' then v_sub.current_period_end end,
        'renewal_date', v_window.renewal,
        'usage_period_start', v_window.period_start,
        'usage_period_end', v_window.period_end,
        'members', v_members
    );
end;
$$;

revoke all on function public.org_billing_overview(uuid) from public, anon;
grant execute on function public.org_billing_overview(uuid) to authenticated, service_role;
