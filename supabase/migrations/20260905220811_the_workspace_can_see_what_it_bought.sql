-- What a workspace is paying for, in one read.
--
-- `org_subscriptions` is already readable by its members, so the plan, the seat
-- count and the period need no function. Two things do: who actually holds the
-- seats, and how much of the pool has been spent. Both are derived — the first
-- from `org_seat_holders`, which is service-role only because it answers "who is
-- covered" about an arbitrary organization, and the second from `usage_events`,
-- which nobody may read across other people.
--
-- So one function, authorized to the organization's own members, that answers
-- exactly the questions the Billing page asks and nothing else. It returns names
-- and emails the roster already shows those same members, and no billing
-- identifiers: `paddle_customer_id` and `paddle_subscription_id` are the
-- organization's payment plumbing, not something a member needs to render a
-- table.
--
-- The seat list carries `holds_seat` for everybody active, not just the covered
-- ones. A workspace that has outgrown its seat count is the case the page exists
-- to make visible — coverage is derived from join order, so somebody is silently
-- outside it and today nothing anywhere says who.

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

    select * into v_plan from public.plans where plan = v_sub.plan;
    select * into v_window from public.monthly_usage_window(
        v_sub.status, null, v_sub.current_period_start, v_sub.current_period_end);

    select coalesce(sum(u.audio_seconds), 0) into v_consumed
      from public.usage_events u
      join public.org_seat_holders(p_org_id) h on h.user_id = u.user_id
     where u.kind = 'transcribe'
       and u.created_at >= v_window.period_start
       and u.created_at <  v_window.period_end;

    v_included := case
        when v_sub.status in ('trialing', 'active')
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
               row_number() over (order by (m.role <> 'owner'), m.joined_at, m.id) as seat,
               row_number() over (order by (m.role <> 'owner'), m.joined_at, m.id) <= v_sub.seats as holds_seat
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
        'status', v_sub.status,
        'seats', v_sub.seats,
        'billing_cycle', (select billing_cycle from public.plan_prices
                           where paddle_price_id = v_sub.paddle_price_id),
        'hours_included', round(v_included / 3600.0, 3),
        'hours_used', round(v_consumed / 3600.0, 3),
        'renewal_date', v_window.renewal,
        'usage_period_start', v_window.period_start,
        'usage_period_end', v_window.period_end,
        'members', v_members
    );
end;
$$;

revoke all on function public.org_billing_overview(uuid) from public, anon;
grant execute on function public.org_billing_overview(uuid) to authenticated, service_role;
